# Controller-run gates: moving resolve gates out of the worker

Status: plan only. Nothing here is built. Written 2026-10-17 against `feature/agent-pool-core` at
`90d9fbf` (PR #2), after review rounds 10491, 10507, 10510 and 10511.

## Decisions this plan implements

- **D1 (Craig, 2026-10-17): "Plan out the move of these commands to the controller."** This is
  option (c) from review 10491. After a resolve worker exits, the controller runs the gate commands
  itself, from a pinned per-repo list. Workers get no keys and never run a gate. Their shell shrinks
  to file edits (through the CLI's own Edit and Write tools) plus a minimal read-only git set.
- **D2 (assumed): one host per repo (cachyos).** Claims, gate receipts, the dependency cache and
  the gate lock are all local files under `$AGENT_POOL_STATE`. Nothing in this plan tries to
  coordinate across hosts.

### Why D1 matters

Today a resolve worker can run `npm run *`, `just *`, `composer test*`, `dotnet build|test*`,
`php artisan test*` and `vendor/bin/{pint,phpunit}*` (`policy.py` `GATES`, lines 123-125, and
`GATE_SHELL`, lines 241-245). The worker can also edit the scripts those commands run, and the
commands run as the user, with the ssh agent and the Gitea token. So any resolve worker can run
arbitrary code with publishing credentials. The pushurl override in `spawn_worker` doesn't stop
`git push ssh://...` to an explicit URL, or a direct call to the Gitea API.

Moving the gates to the controller doesn't stop gate commands from running PR code. They still
do, the same way CI does. What changes is where that code runs and what it can reach:

1. It runs **after** the worker is dead.
2. The **controller** picks the commands, from a manifest the worker cannot change.
3. It runs in a **sandbox** with no network, no ssh agent, no tokens and no home directory.

With the gates gone, the worker no longer needs any command that executes code. Most of the
argument-level policy that review rounds 2 to 4 kept patching (brace expansion, redirection,
`2>&1`, interpreters, pipes, recursive reads) can then be deleted rather than hardened.

---

## 1. The pinned gate manifest

### Where it lives

- **Primary: `.agent-pool/gates.toml` on the PR's base branch.** It is read by blob, never from a
  checkout:
  `git -C "$MAIN" show "$BASE_SHA:.agent-pool/gates.toml"`. `BASE_SHA` is
  `origin/<base_ref>`, resolved once per job after the tick's `git fetch` (`prod-common.sh:722`).
  It is recorded in the gate receipt (§3) together with the manifest's blob SHA. The worker's
  tree, the PR head and the worker's worktree are never consulted. Because the base branch is
  human-merged, only a merged change can alter it.
- **Controller-owned override: `$AGENT_POOL_GATES_DIR/<owner>__<name>.toml`** (default
  `~/.config/agent-pool/gates/`). If this file exists, it wins over the base-branch file. It covers
  repos that shouldn't carry pool files, and lets Craig pin gates before a manifest PR has merged.
  The worker policy already denies reads under `~/.config` paths, and this path is added to
  `SENSITIVE` and `credential_globs()`. The worker has no reason to read it.
- **No manifest found:** a review still runs. For a resolve, the outcome depends on what the
  worker changed. If it touched only paths in the docs-only set (`**/*.md`, `docs/**`), the
  commits are pushed with "no gate applies". Anything else gets `needs-human` with "this repo
  has no gate manifest". The pool never guesses a gate from AGENTS.md.

### Format

TOML, parsed with the stdlib `tomllib` (Python 3.11+, which cachyos has). It is parsed only by a
new `agent-pool/scripts/gates.py`. Commands are argv lists and never shell strings.

```toml
version = 1

[defaults]
timeout   = 600        # seconds per gate
memory    = "4G"       # cgroup MemoryMax
tasks     = 512        # cgroup TasksMax
cpu       = "200%"     # cgroup CPUQuota
budget    = 1200       # total seconds for all gates of one job

# Dependencies are installed offline inside the sandbox, from a cache the controller warms
# from the BASE branch's lockfile (§2.5).
[[deps]]
name     = "client-npm"
cwd      = "clientv2"
lockfile = "clientv2/package-lock.json"
warm     = ["npm", "ci", "--ignore-scripts"]      # controller, base tree, network on
install  = ["npm", "ci", "--offline"]             # sandbox, worker's tree, network off

[[gate]]
name    = "client"
cwd     = "clientv2"
argv    = ["npm", "run", "gate"]
paths   = ["clientv2/**"]                         # run when the worker's diff touches these
timeout = 900

[[gate]]
name  = "net"
argv  = ["dotnet", "build", "Pulse.sln", "-c", "Release", "--no-restore"]
paths = ["net/**", "*.sln", "Directory.Build.*"]

# Paths whose change by the WORKER sends the job to needs-human instead of running gates:
# anything that redefines what a gate does.
protect = ["clientv2/package.json", "justfile", "composer.json", "phpunit.xml*",
           "Directory.Build.*", "*.sln"]
```

`gates.py validate` rejects a manifest that has any of these:

- unknown keys or `version != 1`
- an `argv` that isn't a non-empty list of strings
- an `argv[0]` outside the controller's `GATE_RUNNERS` set (`npm`, `dotnet`, `just`, `composer`,
  `php`, `vendor/bin/pint`, `vendor/bin/phpunit`), which is the old `policy.GATES` moved here
- `sh`, `bash`, `env`, `python*` or `node` anywhere in `argv[0]`
- a `cwd` that isn't a normalised relative path inside the tree
- a timeout above `budget`, or a `budget` above `AGENT_POOL_GATE_BUDGET`

A manifest that fails validation is an **infra** fault (§3), not a gate failure.

`gates.py` subcommands:

| Subcommand | Does |
|---|---|
| `load --main M --base-sha S --repo O/R` | Prints the validated manifest as JSON plus its blob SHA and source (base or override). |
| `select --manifest J --changed FILE` | Prints the gates whose `paths` match the worker's changed files. Prints `none` for a docs-only change. |
| `protected --manifest J --changed FILE` | Prints the changed paths that are protected (built-ins plus `protect`). |
| `run ...` | The sandbox runner (§2). |

### Detecting and rejecting a worker's change to the manifest

In `publish()` (`prod-common.sh:500-543`), right after the fast-forward check at `:525` and the
tool-config check at `:527-528`, the controller computes the worker's changed paths once:

```bash
git -C "$MAIN" diff --name-only --no-renames -z "$sha" "$newhead"
```

It passes them to `gates.py protected`. These paths are always protected, whatever the manifest
says:

- `.agent-pool/**`, which is the manifest itself
- `.gitattributes` and `**/.gitattributes`, because filter, `diff=` and `export-ignore` attributes
  change what the checkout and gates see
- `.gitmodules` and any gitlink (mode 160000) change
- `.lfsconfig`
- `.cursor/**`, `.grok/**` and `.claude/**`, which are already refused at `:527`
- `.agent-pool-context.md`, the context file (also fixes 10511 nit 5)
- every `[[deps]].lockfile`

If any of these match, `PUB="fail:the worker's commits change gate-defining files (<paths>); a
human must review them"`. That sends the job to `needs-human` through `finish_job fail`. No gate
runs and nothing is pushed.

This catches more than manifest edits. It also catches a worker that keeps the pinned `npm run
gate` but rewrites `package.json`'s `gate` script to `true`. The manifest pins the command name,
and `protect` pins what that name means.

The PR's **own** (human-authored) changes to these files are not rejected. Gates always come from
`BASE_SHA`, so a PR that edits `gates.toml` is simply gated by the base version.

---

## 2. How the controller runs the gates

New function `run_gates` in `prod-common.sh`, called from `publish()` for resolve jobs when
`newhead != sha`. It runs **after** these steps:

- `worker_head`
- the marker and head checks
- `headref_safe`
- the fast-forward check
- the protected-path check

It runs **before** these steps:

- the `ls-remote` race check at `:529`
- the guarded push at `:532`

A red gate never reaches origin.

The worker's process group is already dead at this point (`attempt()` calls `kill_worker_group`
at `:600` before `publish`), so no straggler can race the gate checkout.

### 2.1 A clean, controller-owned checkout, by SHA

- **The SHA.** The commit is `newhead` from `worker_head()` (`:447-457`), read through the main
  clone and never through the worker's `.git` pointer. The controller asserts that it is a commit
  (`rev-parse --verify -q "$newhead^{commit}"`) and that `sha` is its ancestor (already done at
  `:525`). After that, everything works by full SHA and never by a ref name the worker could have
  moved.
- **The directory.** It is fresh on every run and is not a git worktree:
  `GATE_DIR="$(mktemp -d "$STATE/gate-work/$(slug "$REPO")-$JOB_PR-XXXXXX")"`. It is outside the
  worker's worktree and `WT_ROOT`. It is removed in `end_job`.
- **Materialising the tree.** The controller uses plumbing into a private index. It doesn't use
  `git worktree add` (which creates a `.git` file plus `$common/worktrees/<id>/` admin files), or
  `git archive` (which honours in-tree `export-ignore` and `export-subst`):

  ```bash
  gate_git read-tree --index-output="$GATE_DIR.index" "$newhead"
  GIT_INDEX_FILE="$GATE_DIR.index" gate_git --work-tree="$GATE_DIR" checkout-index -a -f
  ```

  The gate dir gets **no `.git`**, so a gate can't run git against the main clone. A repo whose
  tests need git history is an open question (§7, Q6).
- **Ignored files.** Untracked or ignored files in the worker's worktree, such as a planted
  `node_modules/.bin/jest`, never reach the gate. Only committed content is checked out.

### 2.2 No worker-controlled git config, hooks, hooksPath, aliases or GIT_* env

`gate_git` is a wrapper used for every controller git call on the gate path:

```bash
gate_git() {
  env -i PATH=/usr/bin:/bin HOME="$STATE/empty-home" LANG=C.UTF-8 \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_DIR="$MAIN_GITDIR" \
    git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.untrackedCache=false \
        -c filter.lfs.smudge= -c filter.lfs.process= -c filter.lfs.required=false \
        -c core.symlinks=true -c core.autocrlf=false "$@"
}
```

How each source of git behaviour is handled:

| Source | Handling |
|---|---|
| `GIT_*` env | `env -i` drops every inherited `GIT_*` (`GIT_DIR`, `GIT_CONFIG_*`, `GIT_EXEC_PATH`, `GIT_SSH*`, `GIT_ASKPASS`, `GIT_PAGER`, ...). The only ones set are those listed above. |
| Global and system config | Ignored. `~/.gitconfig` aliases, `filter.*`, `diff.*.textconv` and `url.*.insteadOf` don't apply. |
| Hooks | `core.hooksPath=/dev/null`. `read-tree` and `checkout-index` run no hooks anyway, but this pins it. |
| Aliases | None. The wrapper only calls the plumbing commands `read-tree`, `checkout-index`, `diff --name-only`, `show <sha>:<path>`, `rev-parse --verify` and `merge-base --is-ancestor`. |
| `MAIN/.git/config` itself | `MAIN_GITDIR` is the main clone's common dir. Its local config is the only config read, and it is controller-owned. A worker can't write it (`git_paths()` denies `**/.git/**`, and Write is scoped to the worktree). As a tamper check, `prod-common.sh` records `sha256sum "$MAIN_GITDIR/config"` at tick start and re-checks it before the gate checkout and before the push. A mismatch is an infra fault and refuses the push. |
| Per-worktree config | Never used. `extensions.worktreeConfig` / `config.worktree` under `worktrees/<id>/` is read only by commands run in that worktree, and the controller never runs one. |
| In-tree `.gitattributes` | Filter drivers only exist if config defines them, and global config is off. `.gitattributes` changes by the worker are also protected (§1). |
| `.gitmodules` | Never initialised. Submodule changes by the worker are protected (§1). |

The same scrubbed env (`env -i`, no global config, `core.hooksPath=/dev/null`) is applied to the
**worker's** git as well, in `spawn_worker` (§5). A worker's own `git log` and `git commit` then
can't pick up `~/.gitconfig` textconv drivers, pagers or hooks.

### 2.3 Sandbox, timeout and resource limits

`gates.py run` builds one command per gate. The outer layer is a transient systemd scope (cgroup
v2 limits), then a timeout, then bubblewrap:

```text
systemd-run --user --scope --quiet --collect
    -p MemoryMax=<memory> -p MemorySwapMax=0 -p TasksMax=<tasks> -p CPUQuota=<cpu>
  timeout -k 30 <timeout>
  bwrap --unshare-all --die-with-parent --new-session --clearenv
        --json-status-fd 3
        --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib /lib64
        --ro-bind /etc/ssl /etc/ssl --ro-bind /etc/ca-certificates /etc/ca-certificates
        --ro-bind-try <each AGENT_POOL_GATE_RO_BINDS toolchain dir>
        --proc /proc --dev /dev --tmpfs /tmp
        --tmpfs /home --dir /home/gate
        --bind "$GATE_DIR" /work --chdir /work/<cwd>
        --ro-bind "$CACHE" /cache
        --setenv HOME /home/gate --setenv PATH /usr/bin:/bin:<toolchain bins>
        --setenv CI 1 --setenv LANG C.UTF-8 --setenv TERM dumb
        --setenv NPM_CONFIG_CACHE /cache/npm --setenv NUGET_PACKAGES /cache/nuget
        --setenv COMPOSER_CACHE_DIR /cache/composer --setenv DOTNET_CLI_TELEMETRY_OPTOUT 1
        -- <argv>
```

- **Separate process group and watcher.** The runner starts under `setsid`. `run_gates` sets
  `WORKER_PG` to its pid and calls the existing `watch_start`, so a superseded claim kills the
  gate exactly as it kills a worker (§3).
- **Per-gate timeout.** `timeout -k 30 <gate.timeout>`.
- **Job budget.** `run_gates` stops starting gates once `budget` is used up and records
  `gate-timeout` for the remainder.
- **Host-wide gate lock.** `flock "$STATE/gates.lock"` around the whole gate run. Ticks for
  different repos then never run two `dotnet build`s at once on cachyos. The wait counts against
  the budget.
- **Fail closed.** If `bwrap` or `systemd-run --user` is missing, or the scope can't be created,
  this is an infra fault (§3). There is no unsandboxed fallback, and no `prlimit` fallback either:
  `RLIMIT_NPROC` is per user and would also throttle the controller and providers.
- **Telling infra from gate.** `--json-status-fd 3` (bubblewrap 0.5+) reports `child-pid` once the
  sandboxed process starts, then `exit-code`. No `child-pid` means bwrap itself failed (infra).
  Exit 126 or 127 from the child means the toolchain isn't bound into the sandbox (infra). The
  cgroup's `memory.events` `oom_kill > 0` marks a resource kill.

### 2.4 An env scrubbed of ssh keys and tokens

- `--clearenv` plus the explicit `--setenv` list above. No `SSH_AUTH_SOCK`, `GITEA_TOKEN`,
  `GH_TOKEN`, `ANTHROPIC_API_KEY`, `NPM_TOKEN`, `XDG_RUNTIME_DIR` or `DBUS_SESSION_BUS_ADDRESS`.
- `/home` is a tmpfs, so `~/.ssh`, `~/.config/tea`, `~/.config/pulse/gitea_token`, `~/.netrc`,
  `~/.git-credentials`, `~/.npmrc`, `~/.claude` and `~/.codex` don't exist inside the sandbox.
  `/run/user/<uid>` (the agent socket) isn't mounted.
- **Toolchains under `$HOME`.** Dirs such as `~/.dotnet` or `~/.npm-global` are bound read-only,
  one directory at a time, from `AGENT_POOL_GATE_RO_BINDS`. `gates.py` refuses any entry that is
  `$HOME` itself or a parent of a `SENSITIVE` path.
- A manifest can't add env vars in v1. If a gate needs one, Craig adds it to the controller-owned
  override (§7, Q5).

### 2.5 Network: none for gates, and how dependencies work without it

Gates run with `--unshare-all`, which includes `--unshare-net`: only a private loopback, no
egress. That is the point of D1. Code the worker could influence never runs with network.

Dependencies come from a controller-owned cache at `$STATE/gate-cache/<repo-slug>/`, with `npm/`,
`nuget/` and `composer/` subdirectories:

1. **Warm (network on, base tree, controller).** When a `[[deps]].lockfile` blob at `BASE_SHA`
   differs from the one recorded in `gate-cache/<slug>/warmed.json`, `run_gates` checks out
   `BASE_SHA` with the same plumbing as §2.1 into a scratch dir. It then runs `warm` in a bwrap
   **with** network but still with `--clearenv` and a tmpfs home: `npm ci --ignore-scripts`,
   `dotnet restore`, `composer install --no-scripts --no-plugins`.
   - This is base-branch code, so it has the same trust as anything already merged. It still never
     sees a key.
   - `dotnet restore` evaluates MSBuild from the base tree. That's acceptable for merged code, and
     recorded as a risk.
2. **Install (network off, worker's tree, sandbox).** `install` runs first inside the gate
   sandbox, against the read-only `/cache`: `npm ci --offline`, `dotnet restore --locked-mode`
   with `NUGET_PACKAGES=/cache/nuget`, and `composer install`, which can only resolve from
   `/cache/composer` because there is no network.
   - Lifecycle scripts may run here, because there's no network and no key.
   - If install fails because a package is missing from the cache, the worker changed
     dependencies. That is already caught earlier, because lockfiles are protected (§1).

Scoping the network to "the npm registry only" would need a filtering proxy. This plan avoids
needing one: worker-influenced code gets no network, and base code gets plain network but no
credentials.

### 2.6 Output capture

- The runner, not the gate, owns both fds. Each gate's stdout and stderr go to **one** file in
  arrival order:
  `$RUNS/gate-$JOB_PR-${ATTEMPT:0:8}-<name>.log`. The runner does `stdout=f, stderr=f` in
  `subprocess.run`, so no `2>&1` appears anywhere, in worker or manifest. The file is capped at
  10 MiB with a "[truncated]" marker. Exit code, duration, and whether the timeout or an OOM kill
  fired go to `gate-…-<name>.json`.
- **What gets posted.** For each gate: name, argv, result and duration. For a failing gate, also
  the last 60 lines of its log, in a `<details>` block.
  - Every line passes through `report.py`'s `leaks_secret` first. A matching line is replaced with
    `[redacted: token-shaped]`.
  - Absolute host paths (`$STATE`, `$HOME`, `$GATE_DIR`) are rewritten to `<state>`, `<home>`
    and `/work`, matching the "no local paths in the report" rule.
  - This is a new `report.py sanitize --file F` subcommand, so there is one secret scanner.

---

## 3. How gate results flow through publish, verify, the claim, and the requeue rules

### The receipt

`run_gates` writes one write-once receipt per attempt at
`$STATE/gates/<slug>__<pr>__<attempt_id>.json`, through `poolstate.save`, and refuses to overwrite
an existing one:

```json
{"version": 1, "attempt_id": "...", "provider": "claude", "pr": 7,
 "base_sha": "...", "pr_head": "<sha>", "head": "<newhead>",
 "manifest": {"source": "base|override", "blob": "<sha>"},
 "result": "pass|none-needed|gate-fail|gate-timeout|gate-resource|protected|infra",
 "gates": [{"name": "client", "argv": [...], "rc": 0, "secs": 212, "log": "gate-...log"}]}
```

It also writes a copy indexed by head at `gates/by-head/<slug>__<pr>__<newhead>.json`, which
`verify()` reads.

### Fencing

- The gate run happens inside the current attempt. `watch_start` watches the gate's process
  group, so a superseded attempt's gates are killed.
- `still_held` is checked after `run_gates` returns. If the claim was lost, `PUB=lost`: nothing is
  pushed or posted, and `run_job` takes its existing `lost` branch (`:678`).
- The push itself still goes through `guarded` (`:532`). The receipt names the `attempt_id`, so a
  late receipt from a superseded attempt can never vouch for a newer attempt's head.

### Deadline

The claim's `expected_deadline_at` must now cover the worker **and** the gates. The startup check
at `:707-708` becomes:

`WORKER_TIMEOUT + AGENT_POOL_GATE_BUDGET + 120 < AGENT_POOL_DEADLINE_SECS`

The current defaults (2400 + 1200 + 120 > 2700) would fail this check. Proposed defaults are
`WORKER_TIMEOUT=1800`, `AGENT_POOL_GATE_BUDGET=1200` and `AGENT_POOL_DEADLINE_SECS=3300` (§7, Q2).

### What the comment carries

`publish` builds the posted comment as:

1. the worker's report
2. a controller-written `### Gates (run by the pool controller)` section
3. `<!-- agent-pool-gates:v1 head=<newhead> manifest=<blob> result=<result> -->`
4. the worker's resolve marker, kept as the last line

`report.py` parses only the last `pulse-resolve` marker, so nothing about marker parsing changes.
The gate marker is informational, for humans and for `pr-merge.sh` later (§7, Q8). The authority
is the local receipt.

### `verify()` and `derive_job()`

- In `verify()` (`:290-339`), for `r_fixed > 0`, add after the fast-forward check at `:329`: read
  `gates/by-head/…__$newsha.json`. If it's missing, or its `result` is not `pass` or
  `none-needed`, return `fail:no passing controller gate record for $newsha`.
- `derive_job()` (`:344-361`) settles a resolve through `verify`, so a resolve pushed without a
  controller gate run is never settled. That covers a legacy `pr-loop.sh` run and a hand push. It
  is re-derived as a review instead (its head no longer equals the review head), which is the
  existing behaviour for a moved head.

### Failure taxonomy

`publish` returns one new `PUB` value, `gateinfra:<why>`. The other gate outcomes reuse `fail:`.

| Class | Detected by | Push | Label (`finish_job`) | Provider cooldown | Setup fault | Comment |
|---|---|---|---|---|---|---|
| **pass** | every selected gate rc 0 | yes | `done` after `verify` ok | `cooldown.py clear` (verified success, `:619`) | no | gate section, all green |
| **none-needed** | `gates.py select` → none (docs-only) | yes | `done` | clear | no | "no gate applies to the changed paths" |
| **protected** | §1 path check | no | `needs-human` (`fail`) | none | no | the protected paths changed |
| **gate-fail** | child started and exited non-zero (not 124/137/126/127) | no | `needs-human` (`fail`) | none, and strikes are **not** cleared | no | failing gate, rc, last 60 lines |
| **gate-timeout** | `timeout` fired (124, or 137 after `-k`), or the budget ran out | no | `needs-human` (`fail`) | none | no | "timed out after Ns; if the gate is just slow, raise its timeout in the manifest" |
| **gate-resource** | `memory.events` `oom_kill > 0`, or `TasksMax` hit | no | `needs-human` (`fail`) | none | no | which limit, last lines |
| **infra** | bwrap/systemd-run missing or failing, no `child-pid` on the status fd, child rc 126/127, manifest unreadable or invalid at `BASE_SHA`, cache warm failure, checkout failure, `MAIN` config checksum mismatch, disk full | no | `ready` (requeue) | **none** for the provider | **yes**, `setup_fault gates "<why>"`, so the tick exits 2 | none (requeue posts nothing) |
| **lost** | `still_held` false after gates | no | untouched | none | no | none |

Notes on the rules:

- **Gate failures are not limits.** They take the `fail:` path, never `fail-nomarker:`, so the
  fast-fail rule at `:629-631` can't turn a quick red gate into a cooldown.
- **The classifier's verdict still comes first.** In `attempt()`, a `cls` of `limit`, `setup` or
  `timeout` is checked before a plain `fail` (`:624-628`). If the provider hit a limit mid-job,
  its commits may be partial, and a red gate is then expected. Cooling the provider down and
  falling through to the next one (existing behaviour) is right there.
- **Infra is handled before `cls`.** `attempt()` maps `gateinfra:*` to `VERDICT=requeue` before
  the `cls` case. Falling through to the next provider would hit the same broken sandbox and burn
  another full `WORKER_TIMEOUT`.
- **Stop claiming while gate infra is broken.** `cooldown.py fault --provider gates` is recorded,
  and `select_providers` is extended: while `faults/gates.json` is newer than the last successful
  gate run, `job_providers resolve` returns nothing. Resolve jobs are then skipped (not claimed)
  until a person fixes the sandbox. Review jobs keep running.
- **A requeue loses the worker's commits.** The worktree is removed, and the next resolve starts
  from scratch. Keeping them under a controller ref so a later tick can re-gate without re-running
  the provider is §7, Q4.
- **The published mark.** Nothing is published on any non-pass path, so `published_mark` (L4) is
  never written and a later stale claim keeps today's strike rules.
- **A red gate at the PR head.** If a gate fails at `newhead`, `run_gates` runs that one gate once
  more at `sha` (the PR head before the worker), within the remaining budget. If it also fails
  there, the comment says "this gate was already red at `<sha>` before the pool's changes". The
  outcome is still `needs-human` and nothing is pushed (§7, Q3).

---

## 4. What `policy.py` can drop

The worker policy becomes file edits through the CLI's own tools plus a minimal read-only git
set. In resolve, there is one deliberate exception: named-path `git add` and `git commit -m`.

### Kept

| Job | Allowed |
|---|---|
| review | `git status`, `git diff`, `git log`, `git show`, with the existing vetted options (`GIT_SPECS` for those four only). Native `Read`, `Grep` and `Glob`, scoped (below). `Write(<report>)`. |
| resolve | Everything review has, plus `Edit` and `Write` on `<wt>/**` (still excluding `.git`, `.cursor`, `.grok`, `.claude`, the context file and `.agent-pool/`), `git add <named paths>`, and `git commit -m <msg>`. |

The `git commit -m` exception keeps per-finding commits, which the report's Fixed section cites,
and the `head=` in the resolve marker. Commit is no longer a code path once
`core.hooksPath=/dev/null` and `GIT_CONFIG_GLOBAL=/dev/null` are forced into the worker's env
(§5). Moving commits to the controller, which would reach the strict target, is §7, Q1.

The resolve prompt's `git rev-parse HEAD` becomes `git log -1 --format=%H`.

### Dropped

| Dropped | Where today | Why it can go |
|---|---|---|
| `GATES`, `GATE_SHELL`, the gate branch of `segment_ok` | `policy.py:123-125`, `:241-245`, `:223-226` | The controller runs gates. |
| `TOOL_SPECS` (`cat ls head tail wc grep rg`) and their `READ_SHELL` globs | `:105-122`, `:240` | The CLIs' own Read, Grep and Glob replace them. Without `head`/`tail`, a pipe has nothing to feed. |
| `git rev-parse`, `ls-files`, `grep`, `blame` from `GIT_SPECS` and `READ_SUBS` | `:90-103`, `:238` | Not in the minimal set. `git log -1 --format=%H` covers the marker head. |
| `python3 <adapter> head\|comments\|threads` | `:212-222`, `:288` | The controller already writes the comments into `.agent-pool-context.md` (`write_context`, `:556-568`). It will also write `threads` and the PR head. The worker never touches the adapter, so it never needs a process that reads `~/.config/pulse/gitea_token`. |
| `git commit -F` / `--file` | `:205-207`, `COMMIT_SHELL` | Closes 10511's `git commit -F ~/.config//tea/config.yml`. |
| Pipes, `&&`, `\|\|`, `;`, newlines as separators | `tokenize`, `SEPARATORS` | A worker command is exactly one simple command. Any operator character denies it outright, so the segment logic collapses to "one segment or deny". |
| `--hidden`, `--no-ignore` and every other tool option | `TOOL_SPECS` | The tools are gone. |
| The deny-list entries for the dropped tools (`rg *--pre*`, `rg *-z*`, `git grep *-O*`, `tail *-f*`, `python3 -c*`, `node*`, `npx*`, `bash*`, `sh *`, `env*`, `eval *`) | `DENY_SHELL :257-261`, `CURSOR_DENY :270-273` | Unreachable under a pure allowlist. The push, `reset --hard` and `merge` denies stay, per the owner decision. |

### Added: a post-expansion check in a PATH shim

`AGENT_POOL_HOME/workerbin/git` is put first on the worker's `PATH`. It calls `policy.py check
--argv` on its **real argv**, which is after the shell has done brace, glob, tilde and quote
expansion, and then execs `/usr/bin/git`. The CLI rules (glob or prefix) remain the first line,
and the shim is the second. The allowlist only permits commands that start with the word `git`,
so a worker can't reach `/usr/bin/git` directly.

### Bypass classes this closes

| Class (review) | How it is closed |
|---|---|
| Brace expansion, e.g. `rg {-,}-pre=sh`, `git log {-,}-output=<path>` (10511 #1) | `rg` is gone. The shim sees `--output=<path>` after expansion and denies it. The raw check also rejects unquoted `{`, `}`, `*`, `?`, `[` and a leading `~`. |
| Redirection, here-strings, `<(...)` (10507 #1, 10511) | Any operator character denies the whole command. Nothing legitimate needs one any more. |
| `2>&1` | Never needed. The runner captures stderr (§2.6), and the CLIs capture the worker's. The "narrow `2>&1` allowance" 10511 suggested is **not built**. |
| Interpreters: `python3`, `node`, `npx`, `sh`, and repo scripts run by `npm run`/`just`/`composer`/`dotnet` (D1) | No allowed command executes code. The only interpreter left was `python3 <adapter>`, and it's gone. |
| Pipes into an executor (`\| sh`, `\| xargs`) | No pipes. |
| Recursive reads of a parent folder (`grep -r token ~/.config`, `rg --hidden --no-ignore BEGIN ~`) (10511 #2) | `grep`/`rg` are gone. Native Read, Grep and Glob are scoped by the Claude hook (`hook()`, `write_allowed`) to `<wt>`, `$RUNS/<this job>` and the context file. They're no longer just checked against `sensitive()` fragments. |
| Unnormalised and wildcard paths (`~/.config//tea`, `/./`, `~/.s*/config`) (10511 #2) | Paths are normalised with `os.path.normpath(os.path.realpath(...))` before the scope check. Shell wildcards are rejected raw and re-checked post-expansion by the shim. |
| Option values naming credentials (`git commit -F <secret>`) (10511 #2) | `-F` is dropped. `-m` takes a literal. |
| `git add ././`, `git add` of tool config (10511, S3) | `add_positional` normalises with `normpath` and refuses anything outside `<wt>` or in the protected set. `publish` re-checks the diff anyway (§1). |
| `git difftool`, `--ext-diff`, `--textconv`, pagers, `-c`/`-C`, `GIT_PAGER=` (10507, 10511) | Still denied by `GIT_SPECS`. With `GIT_CONFIG_GLOBAL=/dev/null` no external diff or textconv driver even exists. |
| Network egress and pushes to an explicit URL from a gate script (D1) | The worker runs no gate. The gate sandbox has no network and no key. |
| Token reads through the adapter process | The worker no longer runs the adapter. |

`SENSITIVE`, `credential_globs()` and `report.py`'s `leaks_secret` stay. Those are the
defence-in-depth for native Read and for posted text.

---

## 5. Impact on the adapters and their permission files and hooks

These changes apply to all providers:

- **`spawn_worker` (`:398-406`)** adds the following to its `env`:
  - `-u SSH_AUTH_SOCK -u GITEA_TOKEN -u GH_TOKEN -u NPM_TOKEN`
  - `PATH="$AGENT_POOL_HOME/workerbin:/usr/bin:/bin"`, so the shim comes first. Provider binaries
    are already launched by absolute path from `bin_for`.
  - `GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1`
  - `GIT_CONFIG_COUNT=4`, with `remote.origin.pushurl` (existing), `core.hooksPath=/dev/null`,
    `user.name` and `user.email`. Commits keep an author once global config is off. The values
    come from `AGENT_POOL_GIT_AUTHOR`.
  - The CLIs keep their own auth (for example `~/.claude/.credentials.json`). "No keys" means no
    ssh or Gitea keys. Model-provider auth is the CLI's own business, and its files are still
    denied to the worker's Read.
- **`write_context` (`:556-568`)** runs for every provider, not only agy (it already does). It also
  adds `threads` JSON, the PR head SHA and the list of gates the controller will run.
- **`exclude_tool_config` (`:219-229`)** adds `/.agent-pool/` to `info/exclude`'s list. The
  `publish` path check at `:527` uses the §1 protected set.

| Adapter | Today | After |
|---|---|---|
| **Claude** (`build_cmd :250-260`) | `--allowedTools` with ~40 Bash globs including the gates and the adapter. `--settings` PreToolUse hook running `policy.py hook`. `--add-dir "$RUNS"`. | `--allowedTools`: `Read Grep Glob Write(//<report>)`, `Bash(git status)`, `Bash(git status *)` and the same for diff, log and show. Resolve adds `Edit(//<wt>/**) Write(//<wt>/**) Bash(git add *) Bash(git commit -m *)`. `--disallowedTools` shrinks to push/reset/merge, `git -c*`, `git -C*`, `*--output*`, `.git/**` writes and credential reads. The hook keeps the same wiring. `hook()` scopes Read, Grep and Glob paths (normalised) to `<wt>`, `$RUNS` and the context file. `--add-dir` narrows from all of `$RUNS` to a per-job `$RUNS/job-<pr>-<attempt>/` that holds the report. |
| **Cursor** (`.cursor/cli.json`, written by `attempt :589-592`) | `Shell(<prefix>)` for every `READ_SHELL`, `GATE_SHELL` and `COMMIT_SHELL` prefix. Prefixes can't constrain arguments (recorded residual). | `Shell(git status)`, `Shell(git diff)`, `Shell(git log)`, `Shell(git show)`, plus resolve `Shell(git add)` and `Shell(git commit -m)`. `Read(**)` narrows to `Read(<wt>/**)` and `Read(<context>)`. The argument residual is now covered by the PATH shim, which checks post-expansion argv whatever the prefix allowed. If Cursor's `hooks.json` `beforeShellExecution` and `beforeReadFile` are confirmed live (§6 step 9), `policy.py cursor-hooks` emits `.cursor/hooks.json` calling `policy.py hook --format cursor`. That gives Cursor the same pre-check Claude has. `.cursor/hooks.json` is added to `info/exclude` and the protected set. |
| **Grok** (`build_cmd :266-272`) | `--allow`/`--deny Bash(<glob>)` for the full read, gate and commit set. | The same short glob list as Claude, through `--allow`. `Read` becomes `Read(<wt>/**)` and `Read(<context>)`. Grok has no hook, so the shim is its post-expansion check. |
| **agy** (`build_cmd :273-278`) | Review in `--mode plan` with no commands, already context-file driven (`review.agy.txt`). Resolve only with `AGY_AUTO_APPROVE=1` and `--dangerously-skip-permissions`. | Review: unchanged. **Resolve: removed.** `--dangerously-skip-permissions` runs any command with the user's ssh agent, so "workers get no keys" can't hold. `job_providers` (`:198-205`) drops agy for resolve unconditionally, and `AGY_AUTO_APPROVE` is retired with a SETUP FAULT if set. (Running agy itself inside bwrap with network is §7, Q7.) |
| **Codex** (`build_cmd :279-282`) | Not in any default order. The `workspace-write` sandbox has no network, so its adapter reads already failed. | Fits the new model better than before. It reads the context file, not the adapter, and runs no gate. No code change beyond the prompt. It's still not in the default order. |

### Prompts (`skills/pr-loops-common/prompts/`)

- **`resolve.generic.txt`**:
  - Step 1 no longer says AGENTS.md names gate commands for the worker to run.
  - Step 2 reads findings and threads from `__CONTEXT__` instead of running the adapter.
  - Step 5 becomes: "Do not run builds, tests or linters; you cannot. After you finish, the pool
    controller runs `__GATES__` on your commits and refuses to push if any is red. Do not edit
    `__PROTECTED__`."
  - "State the gate result" is removed from step 6, because the controller writes that section.
  - The marker's head instruction becomes `git log -1 --format=%H`.
- **`review.generic.txt`** step 1 reads comments from `__CONTEXT__`.
- `render_prompt` (`:570-576`) adds `GATES=` and `PROTECTED=`.

---

## 6. Migration order

Every step keeps `verify-lease.sh` and `verify-providers.sh` green at that step. **Gates move to
the controller (step 4) before the worker loses them (step 7).** Doing it the other way round
would leave a window where resolve pushes are ungated.

**Step 0. Land #2 first.** Clyde finishes round 4 (10511) on #2, including the brace-expansion
blocker and finding 2. Those fixes still matter for review jobs and for the shim's raw check. #2
should **not** add the `2>&1` allowance. One cheap prompt line ("do not append `2>&1`; output is
captured") is fine.

**Step 1. `scripts/gates.py` load/validate/select/protected, plus a sample manifest.**
New `agent-pool/tests/verify-gates.sh` (unit, offline):

- `load` reads only the base blob. A different `gates.toml` in the worktree is ignored, and the
  test asserts the receipt's blob SHA equals the base's.
- The override file wins over the base file.
- Validation rejects each of these: a shell string, `argv[0]=sh`, an unknown key, `cwd=../x`,
  timeout above budget, and an `argv[0]` outside `GATE_RUNNERS`.
- `select` returns `none` for a docs-only diff and the right gates for a mixed diff.
- `protected` flags `.agent-pool/gates.toml`, `.gitattributes`, `.gitmodules`, a gitlink, a
  lockfile and a `protect` entry.

**Step 2. Sandbox runner: `gates.py run`.**
Cases in `verify-gates.sh`. The suite prints `SKIP (bwrap missing)`, counted separately and never
silently passed, when `bwrap` or `systemd-run --user` is absent. The fixture gate is a small
script in a fixture repo.

- With fixture `HOME`/`.ssh/id_test`, `SSH_AUTH_SOCK` and `GITEA_TOKEN` set in the controller's
  env, the gate sees none of them (it dumps `env` and `ls -a ~`).
- A connect to a TCP listener the test opened on the host's 127.0.0.1 fails from inside the
  sandbox.
- A write outside `/work` and `/tmp` fails.
- A gate printing to both fds gets both into one log, in order, with no `2>&1` anywhere.
- `sleep` past the timeout gives `gate-timeout`.
- A memory hog over `MemoryMax=64M` gives `gate-resource`.
- A missing `argv[0]` gives `infra` (127).
- A bwrap that can't start (`AGENT_POOL_GATE_SANDBOX=/nonexistent`) gives `infra`.
- A token-shaped line is redacted by `report.py sanitize`, and host paths are rewritten.

**Step 3. Controller checkout: `gate_git` and `gate_checkout` in `prod-common.sh`.**
`verify-providers.sh` gets a new section, "controller gate checkout":

- A worker commit adding `.gitattributes` with `* filter=evil`, while a fixture
  `GIT_CONFIG_GLOBAL`-style `~/.gitconfig` defines `filter.evil.smudge="touch $TMP/pwned"`, leaves
  `pwned` absent.
- A `post-checkout` hook in `MAIN/.git/hooks` doesn't run.
- `GIT_DIR=/elsewhere` exported in the tick's env is ignored.
- A changed `MAIN/.git/config` checksum gives an infra fault and no push.
- The gate dir has no `.git`, and has none of the worker worktree's untracked files.

**Step 4. Wire `run_gates` into `publish`, with receipts, the comment section and the verdict
mapping.**
New stub behaviours in `verify-providers.sh`. The stub manifest lives in the bare origin's base
branch.

| Behaviour | Asserts |
|---|---|
| `resolve-fix` with gate `true` | pushed (`origin_head` moved), `agent:done`, the comment has the gate section and `agent-pool-gates:v1 … result=pass` before the resolve marker, and a receipt exists keyed by attempt. |
| gate `false` | `agent:needs-human`, `origin_head` unchanged, the comment has the gate name and tail, and no provider cooldown file. |
| gate sleeps past its timeout | `needs-human`, "timed out". |
| sandbox missing | `agent:ready`, `SETUP FAULT [gates]`, `TICK_RC=2`, no provider cooldown, no comment, and the next tick skips resolve jobs while reviews still run. |
| `resolve-gatefile` (worker edits `.agent-pool/gates.toml`) | `needs-human` and a sentinel proving no gate ran. |
| `resolve-gatescript` (worker edits `package.json`) | `needs-human`. |
| `steal` during the gate | `lost`, no push, and the gate's process group is dead. |
| docs-only fix | `none-needed`, pushed. |
| `fixed=0` | no gates run, no push (unchanged). |
| startup check | `WORKER_TIMEOUT + GATE_BUDGET >= DEADLINE` makes the tick die at start. |

**Step 5. `verify()` and `derive_job()` require a passing receipt for `fixed > 0`.**

- A resolve marker at the current head with no receipt isn't `settled`. It is derived as a review.
- With a receipt, it settles as today (the G6 path).

Unit test for the receipt write-once rule: a second write for the same attempt is refused.

**Step 6. Prompts and context.**

- `write_context` adds threads, the head and the gate list for every provider. `verify-providers.sh`
  extends `CONTEXT_DIFF_LINES` to assert threads are present for claude, cursor and grok.
- In the `verify-lease.sh` "prompt rendering" and `verify-providers.sh` "prompts" sections, the
  rendered resolve prompt contains `__GATES__`'s value, and contains none of `npm`, `2>&1`,
  `gitea-pr.py` or `rev-parse`.

**Step 7. Shrink `policy.py` and add the shim.**

`verify-lease.sh` "worker permission policy", in both families:

- Every 10511 probe is denied: `rg {-,}-pre=sh foo`, `git log {-,}-output=/tmp/x HEAD`,
  `grep -r token ~/.config`, `cat ~/.config//tea/config.yml`, `cat ~/.s*/config`,
  `git commit -F ~/.config//tea/config.yml`, `git add ././`.
- Every former gate is denied in resolve: `npm test`, `npm run gate`, `just`, `dotnet test`,
  `composer test`.
- `python3 <adapter> head …` is now denied. Any `|` is denied.
- `git status`, `git diff origin/master...HEAD`, `git log -1 --format=%H`, `git show HEAD`,
  `git add src/a.php` and `git commit -m "fix: x"` are allowed.
- Shim cases run `workerbin/git` with expanded argv, such as `--output=/tmp/x` reached through
  braces, and expect exit 2 with no file created.

Existing tests that asserted gates or adapter reads as **allowed** (`verify-lease.sh:320-330`,
`verify-providers.sh:297`) are inverted, not deleted.

**Step 8. Adapters.**

`verify-providers.sh` adapter-shape cases:

- Claude's `--allowedTools` has no `npm`, `python3` or `rg`.
- Cursor's `cli.json` has no gate prefixes and `Read` is scoped.
- Grok's `--allow` list matches.
- agy is never spawned for resolve even with `AGY_AUTO_APPROVE=1`, and a SETUP FAULT is logged.
- The stub's env dump shows no `SSH_AUTH_SOCK` or `GITEA_TOKEN`, shows
  `GIT_CONFIG_GLOBAL=/dev/null`, and shows `workerbin` first on `PATH`.
- A stub worker running `git log {-,}-output=$TMP/x` through a real `bash -c` creates no file.

**Step 9. Live checks on cachyos** (manual, recorded in the PR):

1. Unprivileged `bwrap --unshare-all` works, since the CachyOS kernel needs user namespaces.
   `systemd-run --user --scope -p MemoryMax=… -p TasksMax=…` works from a systemd user timer
   context, not just an interactive shell. `--json-status-fd` is supported by the installed
   bubblewrap.
2. A real gate run on a scratch clone of one real repo (AMPB `clientv2` `npm run gate`, and one
   `dotnet build`), offline from a warmed cache, inside the budget. Record durations to set
   defaults.
3. Claude end to end on a scratch PR. The shrunk allowlist plus hook lets it read, edit and
   commit. The PreToolUse hook and `--add-dir` work for real (also an open item from 10510).
4. Cursor: whether `hooks.json` `beforeShellExecution` fires in headless `-p` mode. If it doesn't,
   Cursor resolve relies on the shim.
5. Grok: whether its Bash tool inherits the env `PATH`, so the shim is reached.
6. Confirm a real resolve's comment renders the gate section, with no host paths and no secrets.

**Step 10. Docs and doctor.**

- `agent-pool-worker-pool.md` records D1 as decided (pointing here) and D2 as one host per repo.
- Remove "Gate commands run code the resolve worker can edit" from Open questions.
- Add the gate knobs to the `prod-common.sh` header.
- When `doctor.sh` is built, it checks for bwrap and systemd-run, a writable gate cache, and a
  stale `faults/gates.json`.

**Optional Step 11 (after live use). Gates on review jobs.** The controller runs the manifest's
gates at the PR head before spawning a reviewer and writes the results into the context file. The
review can then say "gate red at head" without any provider running anything. This is cheap once
steps 1 to 4 exist.

---

## 7. Open questions and risks for Craig

**Questions**

1. **Should the controller make the commits too?** That reaches the strict "edits plus read-only
   git" target: no `git add` or `git commit` for workers at all. The controller would commit the
   worktree's diff, minus excluded paths, after the worker exits, with a message taken from the
   report. The cost is per-finding commits, and a resolve marker whose `head=` the worker can no
   longer know, which would mean a `marker.py` change shared with `pr-loop.sh`. **Recommendation:
   no for this PR.** After §5, commit runs no hooks, no global config and no `-F`.
2. **Timing defaults.** Do `WORKER_TIMEOUT=1800`, `AGENT_POOL_GATE_BUDGET=1200` and
   `AGENT_POOL_DEADLINE_SECS=3300` suit you? The alternative is keeping a 2400s worker and raising
   the deadline to 3900. Durations from step 9.2 should decide.
3. **A gate that was already red at the PR head.** Push the worker's fixes anyway, labelled with
   the caveat, or `needs-human` without pushing? The plan says don't push. That is conservative,
   but a PR with a pre-existing red gate then can never be resolved by the pool.
4. **Keep the worker's commits across an infra requeue?** One option is a controller-only ref
   `refs/agent-pool/pending/<pr>/<attempt>` in `MAIN`. The next tick then re-gates without
   re-running the provider. This saves a provider run per sandbox hiccup, but adds a new state to
   reconcile. Not in v1 unless you want it.
5. **Gate env and private registries.** Does any repo need an env var or a registry token for
   `warm`? A token would only ever be given to the warm step, which runs base code, never to a
   gate. It would come from the controller-owned override, not the base manifest.
6. **Tests that need git.** Do any gates need a `.git` (for example `git describe` in a build, or
   tests that shell out to git)? If so, the plan adds a manifest flag `git = true`. The controller
   then `git init`s the gate dir and writes the single commit's objects into it with
   `gate_git pack-objects | index-pack`. The result has history depth 1 and no config, hooks or
   remotes.
7. **agy resolve.** It's removed in this plan. Running agy inside bwrap would need network for its
   own API, which can't be scoped without a proxy, plus a home it can authenticate from. Is losing
   agy resolve acceptable? Review stays.
8. **The merge loop.** Should the controller also post a Gitea commit status
   (`agent-pool/gates: success` on `newhead`) so `pr-merge.sh` can require it? Its header already
   has a TODO for required status contexts. That needs a `status` write in `gitea-pr.py`.
   Suggested as a follow-up to this one.

**Risks**

- **Gates still run PR code.** The sandbox is what contains it, so a bwrap or kernel escape is
  the residual risk. A separate unix user for gates (D1's option (b)) is the next layer if you
  want one. It's not in this plan.
- **Warm runs base-branch code with network.** That's `dotnet restore` MSBuild evaluation, and
  `npm`/`composer` with scripts disabled. It never sees a key. A malicious merged commit could
  still exfiltrate what the sandbox can see, which is the base tree.
- **Gate integrity is not the same as test integrity.** `protect` stops the worker redefining
  the gate *command*. It doesn't stop the worker deleting or weakening a test. That is still the
  reviewer's job: the next review pass sees the diff.
- **Cursor's `Read`/`Write` globs and Grok's rules have no hook.** Their scope is only as good as
  each CLI's matcher. The shim covers git argv, but not native file tools.
- **Local state is load-bearing.** Receipts, cache and `faults/gates.json` live on one host,
  consistent with D2. A second host would not see receipts, and would refuse to settle resolves
  the first host gated. That's safe but noisy.
- **Disk.** A full gate dir per job (with `node_modules`) plus a per-repo cache. `end_job` removes
  the gate dir. The cache needs a size cap or a pruning step in `doctor.sh`.

---

## 8. Recommendation: a follow-up PR after #2 merges

**Land this as its own PR on top of `master` once #2 has merged. Don't fold it into #2.**

- **#2 is still moving.** Clyde is fixing round-4 findings (10511) on #2 right now, and they're in
  exactly the files this plan rewrites: `policy.py`'s `tokenize`, `sensitive` and `options_ok`,
  and `prod-common.sh`'s `publish`. Folding this in would make Clyde's in-flight fixes and this
  redesign conflict. It would also restart the review count on a PR that is converging (465 and
  214 offline tests, four rounds, one blocker left).
- **The two have different review shapes.** #2 is "is this controller correct". This change is
  "is this trust model right": a sandbox, a manifest format and a gate taxonomy. It also needs live
  checks on cachyos (§6 step 9) that #2 doesn't, and those shouldn't block #2.
- **Merging #2 first is safe.** Nothing in #2 is live: `PROVIDER_ORDER` defaults to Claude, and
  there are no entrypoints and no systemd units. The D1 exposure only exists once resolve jobs run
  unattended. Until this follow-up lands, record in the plan doc (one line, which Clyde can add in
  round 4) that **resolve jobs are not to be scheduled unattended**.
- **#2's round-4 fixes aren't wasted.** The brace and path-normalisation fixes are reused by the
  shim's raw check and by the review policy. The only round-4 suggestion to skip is the narrow
  `2>&1` allowance, because step 7 deletes the reason for it.
- **Ordering inside the follow-up matters.** Steps 1 to 6 add controller gates, and step 7 then
  removes worker gates. That's easier to review as a short stack of commits on a fresh branch than
  as more commits on top of #2's four rounds.
