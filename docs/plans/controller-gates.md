# Controller-run gates and controller-made commits

Status: plan only. Nothing here is built. Written 2026-10-17 against `feature/agent-pool-core` at
`90d9fbf` (PR #2), after review rounds 10491, 10507, 10510 and 10511. Revised 2026-10-20 to apply
the Oct 17 decisions (§7).

## Decisions this plan implements

- **D1 (Craig, 2026-10-17): "Plan out the move of these commands to the controller."** This is
  option (c) from review 10491. After a resolve worker exits, the controller runs the gate commands
  itself, from a pinned per-repo list. Workers get no keys and never run a gate.
- **D2 (assumed): one host per repo (cachyos).** Claims, gate receipts, checkpoint refs, the
  dependency cache and the gate lock are all local to that host: files under `$AGENT_POOL_STATE`
  and refs in the main clone. Nothing in this plan tries to coordinate across hosts.
- **The Oct 17 decisions (§7)** take D1 further:
  - The controller makes every commit, signed with a key only it can reach. Workers only edit
    files, and their git is read-only (`status`, `diff`, `log`, `show`).
  - The controller checkpoints the worker's tree while it runs, so a rate-limit cutoff loses no
    work.
  - Gates are baseline-relative. Fixes are pushed when they add no new failures, even if a gate
    was already red.
  - The controller posts an `agent-pool/gates` commit status, and `pr-merge.sh` requires it.

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

With the gates and commits gone, the worker no longer needs any command that executes code or
writes to git. Most of the argument-level policy that review rounds 2 to 4 kept patching (brace
expansion, redirection, `2>&1`, interpreters, pipes, recursive reads, `git commit -F`, `git add
././`) can then be deleted rather than hardened.

---

## 1. The pinned gate manifest

### Where it lives

- **Primary: `.agent-pool/gates.toml` on the PR's base branch.** It is read by blob, never from a
  checkout:
  `git -C "$MAIN" show "$BASE_SHA:.agent-pool/gates.toml"`. `BASE_SHA` is
  `origin/<base_ref>`, resolved once per job after the tick's `git fetch` (`prod-common.sh:722`).
  It is recorded in the gate receipt (§4) together with the manifest's blob SHA. The worker's
  tree, the PR head and the worker's worktree are never consulted. Because the base branch is
  human-merged, only a merged change can alter it.
- **Controller-owned override: `$AGENT_POOL_GATES_DIR/<owner>__<name>.toml`** (default
  `~/.config/agent-pool/gates/`). If this file exists, it wins over the base-branch file. It covers
  repos that shouldn't carry pool files, and lets Craig pin gates before a manifest PR has merged.
  The worker policy already denies reads under `~/.config` paths. All of `~/.config/agent-pool/`,
  which also holds the signing key (§2.3), is added to `SENSITIVE` and `credential_globs()`.
- **No manifest found:** a review still runs. For a resolve, the outcome depends on what the
  worker changed. If it touched only paths in the docs-only set (`**/*.md`, `docs/**`), the
  commit is pushed with "no gate applies". Anything else gets `needs-human` with "this repo has
  no gate manifest". The pool never guesses a gate from AGENTS.md.

### Format

TOML, parsed with the stdlib `tomllib` (Python 3.11+, which cachyos has). It is parsed only by a
new `agent-pool/scripts/gates.py`. Commands are argv lists and never shell strings.

```toml
version = 1

[defaults]
timeout   = 600        # seconds per gate run (candidate and baseline are separate runs)
memory    = "4G"       # cgroup MemoryMax
tasks     = 512        # cgroup TasksMax
cpu       = "200%"     # cgroup CPUQuota
budget    = 1200       # total seconds for all gate runs of one job, baseline runs included

# Dependencies are installed offline inside the sandbox, from a cache the controller warms
# from the lockfile as of the PR head the worker started from (§3.4).
[[deps]]
name     = "client-npm"
cwd      = "clientv2"
lockfile = "clientv2/package-lock.json"
warm     = ["npm", "ci", "--ignore-scripts"]      # controller, network on, no keys
install  = ["npm", "ci", "--offline"]             # sandbox, network off

[[gate]]
name    = "client"
cwd     = "clientv2"
argv    = ["npm", "run", "gate"]
paths   = ["clientv2/**"]                         # run when the worker's diff touches these
timeout = 900
compare = "junit"                                 # how a "new failure" is defined (§3.5)
report  = "clientv2/reports/junit*.xml"

[[gate]]
name    = "net"
argv    = ["dotnet", "build", "Pulse.sln", "-c", "Release", "--no-restore"]
paths   = ["net/**", "*.sln", "Directory.Build.*"]
compare = "lines"
key     = '^(?P<file>[^(]+)\(\d+,\d+\): (?:error|warning) (?P<code>[A-Z]+\d+): (?P<msg>.*?)(?: \[.*\])?$'

# Paths whose change by the WORKER is refused (§2.2): anything that redefines what a gate does.
protect = ["clientv2/package.json", "justfile", "composer.json", "phpunit.xml*",
           "Directory.Build.*", "*.sln"]
```

`gates.py validate` rejects a manifest that has any of these:

- unknown keys or `version != 1`
- an `argv` that isn't a non-empty list of strings
- an `argv[0]` outside the controller's `GATE_RUNNERS` set (`npm`, `dotnet`, `just`, `composer`,
  `php`, `vendor/bin/pint`, `vendor/bin/phpunit`), which is the old `policy.GATES` moved here
- `sh`, `bash`, `env`, `python*` or `node` anywhere in `argv[0]`
- a `cwd` or `report` that isn't a normalised relative path (or glob) inside the tree
- a timeout above `budget`, or a `budget` above `AGENT_POOL_GATE_BUDGET`
- a `compare` other than `exit` (the default), `junit` or `lines`; `junit` without `report`;
  `lines` without a `key` that compiles under Python `re`, is under 512 characters, and has at
  least one named group
- `needs_git = true`. The key name is **reserved**. v1 assumes no gate needs `.git` (§7, decision
  7), so the gate dir has none. Accepting the key later is then not a format break. Until then,
  setting it is a validation error that says "needs_git is not supported yet".
- an `env` table. No gate gets extra env vars in v1, and no registry tokens are plumbed (§7,
  decision 6).

A manifest that fails validation is an **infra** fault (§4), not a gate failure.

`gates.py` subcommands:

| Subcommand | Does |
|---|---|
| `load --main M --base-sha S --repo O/R` | Prints the validated manifest as JSON plus its blob SHA and source (base or override). |
| `select --manifest J --changed FILE` | Prints the gates whose `paths` match the changed files. Prints `none` for a docs-only change. |
| `protected --manifest J --changed FILE` | Prints the changed paths that are protected (built-ins plus `protect`). |
| `run ...` | The sandbox runner (§3). |
| `compare --manifest J --gate N --base B.json --cand C.json` | Prints the new failures for one gate (§3.5). |

### The protected set

The controller checks every path the worker changed against this set when it stages the worker's
tree (§2.2). These paths are always protected, whatever the manifest says:

- `.agent-pool/**`, which is the manifest itself
- `.gitattributes` and `**/.gitattributes`, because filter, `diff=` and `export-ignore` attributes
  change what the checkout and gates see
- `.gitmodules` and any gitlink (mode 160000) change
- `.lfsconfig`
- `.cursor/**`, `.grok/**` and `.claude/**`, which are already refused at `:527`
- `.agent-pool-context.md`, the context file (also fixes 10511 nit 5)
- every `[[deps]].lockfile`

The manifest's `protect` list adds to it. This catches more than manifest edits. It also catches
a worker that keeps the pinned `npm run gate` but rewrites `package.json`'s `gate` script to
`true`. The manifest pins the command name, and `protect` pins what that name means.

The PR's **own** (human-authored) changes to these files are not rejected. Gates always come from
`BASE_SHA`, so a PR that edits `gates.toml` is simply gated by the base version.

---

## 2. The controller's git: commits, signing and checkpoints

Workers only edit files (§5). The controller turns the worker's tree into signed commits. It
writes them twice:

- **Checkpoints**, during the run, to a per-attempt ref.
- **One final commit**, after the worker is dead, which is gated and pushed.

### 2.1 No worker-controlled git config, hooks, hooksPath, aliases or GIT_* env

`gate_git` is a wrapper used for every controller git call on the commit and gate paths:

```bash
gate_git() {
  env -i PATH=/usr/bin:/bin HOME="$STATE/empty-home" LANG=C.UTF-8 \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_DIR="$MAIN_GITDIR" \
    ${GIT_INDEX_FILE:+GIT_INDEX_FILE="$GIT_INDEX_FILE"} \
    ${GIT_AUTHOR_NAME:+GIT_AUTHOR_NAME="$GIT_AUTHOR_NAME" GIT_AUTHOR_EMAIL="$GIT_AUTHOR_EMAIL"} \
    ${GIT_COMMITTER_NAME:+GIT_COMMITTER_NAME="$GIT_COMMITTER_NAME" GIT_COMMITTER_EMAIL="$GIT_COMMITTER_EMAIL"} \
    git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.untrackedCache=false \
        -c core.excludesFile=/dev/null -c filter.lfs.smudge= -c filter.lfs.clean= \
        -c filter.lfs.process= -c filter.lfs.required=false \
        -c core.symlinks=true -c core.autocrlf=false -c core.fileMode=true "$@"
}
```

How each source of git behaviour is handled:

| Source | Handling |
|---|---|
| `GIT_*` env | `env -i` drops every inherited `GIT_*` (`GIT_DIR`, `GIT_CONFIG_*`, `GIT_EXEC_PATH`, `GIT_SSH*`, `GIT_ASKPASS`, `GIT_PAGER`, ...). The only ones set are those listed above, plus the author and committer identity in `sign_git` (§2.3). |
| Global and system config | Ignored. `~/.gitconfig` aliases, `filter.*`, `diff.*.textconv`, `url.*.insteadOf`, `user.signingkey` and `gpg.*` don't apply. |
| Hooks | `core.hooksPath=/dev/null`. `read-tree`, `add`, `commit-tree` and `update-ref` run no commit hooks anyway, but this pins it. |
| Aliases | None. The wrapper only calls `read-tree`, `checkout-index`, `add -A`, `diff-index --raw`, `update-index --index-info`, `write-tree`, `commit-tree`, `update-ref`, `verify-commit`, `diff --name-only`, `show <sha>:<path>`, `rev-parse --verify` and `merge-base --is-ancestor`. |
| `MAIN/.git/config` itself | `MAIN_GITDIR` is the main clone's common dir. Its local config is the only config read, and it is controller-owned. A worker can't write it: it has no git write command (§5), and Write is scoped to the worktree minus `.git`. As a tamper check, `prod-common.sh` records `sha256sum "$MAIN_GITDIR/config"` at tick start. It re-checks the checksum before every checkpoint, before the gate checkout and before the push. A mismatch is an infra fault and refuses the push. |
| Per-worktree config | Never used. The controller addresses the worker's files with `--work-tree="$JOB_WT"` and `GIT_DIR="$MAIN_GITDIR"`. It never runs a command inside the worktree after the worker started, so the worktree's `.git` file, `worktrees/<id>/config.worktree` and index are never read. |
| In-tree `.gitattributes` | Filter drivers only exist if config defines them, and global config is off. `.gitattributes` changes by the worker are also protected (§1). |
| In-tree `.gitignore` | Honoured by `add -A`, so stray build output isn't committed. A worker that edits `.gitignore` can only hide its own files from its own commit. `core.excludesFile=/dev/null` stops the user's global excludes from applying. |
| `.gitmodules` | Never initialised. Submodule changes by the worker are protected (§1). |

### 2.2 Staging the worker's tree

New function `stage_tree <mode>` in `prod-common.sh`. It works the same way for checkpoints and
for the final commit, and always diffs against `sha`, the PR head the job started from:

```bash
IDX="$STATE/stage/$(slug "$REPO")-$JOB_PR-$ATTEMPT.index"
gate_git read-tree --index-output="$IDX" "$sha"
GIT_INDEX_FILE="$IDX" gate_git --work-tree="$JOB_WT" add -A -- .
GIT_INDEX_FILE="$IDX" gate_git diff-index --cached --raw -z --no-renames "$sha"
```

`gates.py stage-check` reads the raw diff and rejects these entries:

| Rejected | How it shows in `--raw` |
|---|---|
| a protected path (§1) | path match |
| a symlink, new or changed into one | new mode `120000` |
| a gitlink | either mode `160000` |
| a mode change | status `M` or `T` with old mode ≠ new mode |
| a new executable file | status `A` with new mode `100755` |
| an oversized blob | blob size above `AGENT_POOL_MAX_BLOB` (default 5 MiB) |
| too many paths | more than `AGENT_POOL_MAX_PATHS` (default 2000) changed entries |

What happens to a rejected entry depends on the mode:

- **`strict`** is used for the final commit. Any rejected entry is
  `PUB="fail:the worker changed <paths> (<reasons>); a human must review them"`. That goes to
  `needs-human`, no gate runs, and nothing is pushed.
- **`drop`** is used for checkpoints. Rejected entries are reset to their `sha` version in the
  private index (`update-index --index-info`, or `--force-remove` for an add) and listed in the
  checkpoint's `Agent-Dropped:` trailer. Checkpoints keep everything else, and the final strict
  stage still refuses the job.

`TREE="$(GIT_INDEX_FILE="$IDX" gate_git write-tree)"`. The private index is removed in `end_job`.

Before staging, `publish` also asserts that `worker_head "$JOB_WT"` (`:447-457`) still equals
`sha`. Workers have no git command that moves HEAD, so a moved HEAD is a tamper signal and a
`fail:`.

### 2.3 Signing: ssh, with a controller-owned key file

**Choice: ssh signing (`gpg.format=ssh`), not gpg.** Reasons:

- **No agent socket.** gpg signs through `gpg-agent`, a long-lived per-user daemon listening on
  `/run/user/<uid>/gnupg/S.gpg-agent`. Any same-uid process that can reach that socket gets
  signatures once the key is unlocked. That is the same credential-by-socket shape D1 removes for
  the ssh agent. `ssh-keygen -Y sign` reads the key file directly in one short-lived process, and
  the key is never loaded into any agent.
- **Plain-file verification.** Verifying needs only an `allowed_signers` file and
  `ssh-keygen -Y verify`. There is no keyring or trustdb. `verify-lease.sh`, `verify()` and
  `pr-merge.sh` can all verify offline from the same file.
- **Gitea supports it.** Gitea verifies ssh-signed commits against ssh keys on the committer's
  account (§4.5).
- **The cost is acceptable.** There are no subkeys and no revocation servers. Rotation means a new
  key file plus a new `allowed_signers` line. The old line gets `valid-before="<date>"`, so old
  commits still verify.

**The key:**

| File | Contents |
|---|---|
| `~/.config/agent-pool/signing/pool_ed25519` | ed25519 private key, no passphrase, mode `0600`, dir `0700`. Dedicated to commit signing. It is not Craig's key, not the push key, and never added to an ssh agent. |
| `~/.config/agent-pool/signing/pool_ed25519.pub` | Public key, also registered on the Gitea pool account (§4.5). |
| `~/.config/agent-pool/signing/allowed_signers` | `<pool email> namespaces="git" ssh-ed25519 AAAA…`. |

The directory is overridable with `AGENT_POOL_SIGNING_DIR`. There's no passphrase because an
unattended controller would need an agent to hold it, and an agent socket is what the choice
above avoids.

**Who can't reach it:**

- **Gate sandboxes.** `/home` is a tmpfs (§3.2). `gates.py` refuses any `AGENT_POOL_GATE_RO_BINDS`
  entry that is `~/.config` or a parent of it.
- **Workers.** `~/.config/agent-pool/**` is in `SENSITIVE`. Claude's hook scopes native Read,
  Grep and Glob to `<wt>`, the per-job dir and the context file. Cursor's and Grok's Read globs
  are `<wt>/**` plus the context file. Workers have no shell that executes code (§5).
- **The residual.** Until workers run in the bwrap jail (§6 step 13), a worker is the same unix
  user. A CLI file-tool bug that ignores its scope could still read the key file. The jail removes
  this, because the key directory is simply not mounted. Step 13 is the precondition for
  re-enabling agy resolve (decision 8).

`sign_git` is `gate_git` plus the signing config and the pool identity:

```bash
sign_git() {
  GIT_AUTHOR_NAME="$POOL_NAME" GIT_AUTHOR_EMAIL="$POOL_EMAIL" \
  GIT_COMMITTER_NAME="$POOL_NAME" GIT_COMMITTER_EMAIL="$POOL_EMAIL" \
  gate_git -c gpg.format=ssh -c gpg.ssh.program=/usr/bin/ssh-keygen \
           -c user.signingkey="$SIGN_DIR/pool_ed25519" \
           -c gpg.ssh.allowedSignersFile="$SIGN_DIR/allowed_signers" "$@"
}
```

`gate_git` passes these four identity variables through its `env -i` list only when they are set,
so only `sign_git` calls carry them. `prod-common.sh` unsets every inherited `GIT_*` variable at
tick start, so an exported identity in the tick's environment can't leak in. `POOL_NAME` and
`POOL_EMAIL` come from `AGENT_POOL_COMMIT_IDENT` (default
`agent-pool <agent-pool@noreply.<gitea host>>`). The startup check verifies that the key file
exists with mode `0600` and is listed in `allowed_signers`. If it isn't, that's
`setup_fault signing`, and the tick claims no resolve jobs.

### 2.4 Commit messages and trailers

**Trailers.** Every pool commit, checkpoint or final, ends with a controller-written trailer block.
Its values come only from the claim record and adapter metadata. They never come from worker
text.

```text
Agent-Provider: claude                        # claim record .provider
Agent-Model: opus                             # model_for(provider), or the model the CLI's own
                                              #   structured output reports (classify.py)
Agent-Attempt: 3f2c…-…                        # claim record .attempt_id
Agent-Job: resolve owner/repo#7 review=<sha>  # claim record .job, repo, PR; REVIEW_HEAD
Agent-Resumed-From: <attempt_id> (cursor/auto)  # one per earlier attempt whose checkpoint this builds on
Agent-Checkpoint: 4                           # checkpoints only
Agent-Dropped: .gitattributes (protected)     # checkpoints only, when stage_tree drop removed entries
Co-authored-by: Claude <noreply@anthropic.com>  # optional, AGENT_POOL_COAUTHOR_<PROVIDER>
```

`report.py trailers` builds the block and validates each value. The provider must be in the
known set. The model must match `^[A-Za-z0-9._:/@+-]{1,64}$`, or it is written as `unknown`. The
attempt must be a uuid4. `Co-authored-by` must be `Name <email>` from controller config, and it is
off by default.

**Messages: the worker proposes and the controller sanitizes.**

- The resolve prompt asks the worker to write a proposed message to `__COMMIT_MSG__`, which is
  `$RUNS/job-<pr>-<attempt8>/commit-msg.txt`, next to its report.
- `report.py commit-msg --file F --fallback "<subject>"` does the following:
  - reads at most 8 KiB as UTF-8 with replacement, normalises CRLF, and drops control characters
    except `\n` and `\t`
  - takes the first non-empty line as the subject and caps it at 72 characters. It refuses a
    `fixup!`, `squash!` or `amend!` prefix.
  - caps the body at 60 lines of 100 characters
  - deletes every line that looks like a trailer with a reserved key (`Agent-*`,
    `Co-authored-by`, `Signed-off-by`, `Reviewed-by`, `Change-Id`, case-insensitive) anywhere in
    the message
  - removes `<!--` and `-->`
  - replaces any line `leaks_secret` matches with `[redacted: token-shaped]`
- If nothing usable is left, the controller writes the subject itself:
  `agent-pool: address review <review8> on #<pr>`.
- The controller then appends a blank line and the trailer block. Its block is always the final
  paragraph, which is the only paragraph git's trailer parser reads.
- Checkpoint messages are always controller-written:
  `agent-pool checkpoint <n> for #<pr> (<provider>)`.

Why the worker proposes: it knows what it changed. The controller keeps the structure and the
attribution, so a worker can't forge them.

### 2.5 Checkpoints during the run

New `ckpt_start` and `ckpt_stop` start and stop a controller loop next to `watch_start`. It runs
only while the worker runs:

- **When.** It checkpoints every `AGENT_POOL_CHECKPOINT_SECS` (default 300) if the tree changed. It
  also checkpoints at **step boundaries** when it gets one. Claude gets a `PostToolUse` hook on
  `Edit|Write` (same `--settings` file as the PreToolUse hook) that touches
  `$RUNS/job-…/dirty`. The loop polls that flag every 15s, and checkpoints at most once per 60s.
  Cursor and Grok have no hook, so they get the timer only.
- **What.** It runs `stage_tree drop`. If `TREE` equals the previous checkpoint's tree, it does
  nothing. Otherwise it creates
  `C=$(sign_git commit-tree -S "$TREE" -p "$PREV" -F "$msg")`, where `PREV` is the previous
  checkpoint (or `sha` for the first). It then runs
  `gate_git update-ref "refs/agent-pool/attempts/$ATTEMPT" "$C" "$PREV_OR_EMPTY"`.
- **Fencing.** Before every update-ref, the loop checks three things: `claim check --attempt
  "$ATTEMPT"` passes, `now < expected_deadline_at` from the claim record, and the `MAIN` config
  checksum is unchanged. If any check fails, it writes nothing and exits. A stale holder therefore
  never adds a checkpoint once it is past its deadline or superseded.
- **The resume pointer.** After a successful update-ref, the loop writes
  `$STATE/checkpoints/<slug>__<pr>.json` through `poolstate.save`. The write is fenced the same
  way. The pointer holds the commit, attempt, provider, model, `sha`, `REVIEW_HEAD`, `n`, and
  `final: false`.
- **The final checkpoint.** In `attempt()`, right after `wait "$WORKER_PG"` and before classify,
  the controller stops the loop and kills the worker group. If `still_held`, it takes one last
  checkpoint. That runs whatever ended the worker: exit, `WORKER_TIMEOUT`, a rate limit or a crash.
  **A cutoff loses no work.**
- **Half-written files.** A timer checkpoint may catch a file mid-write. That is acceptable for a
  resume point. The final commit is staged after the worker is dead, and it is what gets gated.

### 2.6 Resuming from a checkpoint

`prepare_worktree` reads the resume pointer. It resumes when all of these hold:

- `pointer.sha == sha`, so the PR head hasn't moved since.
- `pointer.review_head == REVIEW_HEAD`, so the same review is being answered.
- `sign_git verify-commit` passes on the commit, and its `Agent-Attempt` trailer matches
  `pointer.attempt`.
- `sha` is an ancestor of the commit.

If any check fails, the pointer is discarded (moved to `checkpoints/stale/`), and the attempt
starts fresh from `sha`.

To resume, the controller checks out the worktree at `sha` as today. Before the worker starts, it
lays the checkpoint's tree over it:

```bash
git -C "$JOB_WT" read-tree -u --reset "$ckpt"   # working tree := checkpoint tree
git -C "$JOB_WT" read-tree "$sha"               # index back to sha, so `git diff` shows all the work
```

HEAD stays at `sha`, so the worker's plain `git diff` and `git status` show everything done so
far. The context file gets a "Resuming" section. It names the earlier provider and model, the
checkpoint number, and the earlier attempt's partial report if one exists. The new attempt's
first checkpoint uses the resumed commit as its parent. The final commit carries
`Agent-Resumed-From:` for each earlier attempt.

This covers both cases in decision 2:

- the next provider in the same job (`reattempt` after a `limit` or `timeout`)
- the next tick, after a requeue or a stale takeover

### 2.7 The final commit and push policy

**Recommendation: gate and push one squashed commit per job. Never push checkpoints.**

- **The final commit.** `C=$(sign_git commit-tree -S "$TREE" -p "$sha" -F "$msg")` is built from
  `stage_tree strict`. Its parent is `sha`, never the checkpoint chain. It is written to
  `refs/agent-pool/final/$ATTEMPT`, and the resume pointer is updated with `final: true`, the
  commit, and the report path. This is the commit the gates check (§3), the receipt names (§4)
  and the push sends.
- **Squash, not keep.** The PR gets one reviewable commit per resolve. WIP states, including
  half-written files, never reach the branch. The gates, the receipt and the commit status all
  vouch for exactly the commit that lands. The cost is per-finding commits. The report's Fixed
  section cites files and lines instead of SHAs.
- **Checkpoints stay local (no WIP push).** They live only in `MAIN` on cachyos, consistent with
  D2. Pushing WIP would put ungated, unreviewed code on the shared server, and a single-host pool
  gains no durability from it. Off-host backup is an open question (§7).
- **Stale holders.** A stale holder's checkpoints are **never pushed**. Four things enforce this:
  - The checkpointer stops writing once the holder is superseded or past its deadline (§2.5).
  - The push happens only in `publish`, after `still_held`.
  - The pushed commit's parent is `sha`. It is a fresh final commit, never an attempt ref.
  - `publish` refuses to push a commit unless its receipt's `attempt_id` is the current attempt.

  The resume pointer only ever records checkpoints written while the claim was current and inside
  its deadline. Work a successor builds on is therefore work that was done in time, and it is
  re-gated inside the successor's own final commit.
- **Retention.** `refs/agent-pool/attempts/*` and `refs/agent-pool/final/*` for a PR are deleted
  14 days after the job settles or the PR closes. `reconcile_pr` deletes them, and `doctor.sh`
  sweeps them later. They are never fetched, pushed or packed into anything the worker sees.

---

## 3. How the controller runs the gates

New function `run_gates` in `prod-common.sh`, called from `publish()` for resolve jobs when the
final commit `C` differs from `sha`.

It runs **after** these steps:

- the report and marker checks
- `headref_safe`
- the final checkpoint
- `stage_tree strict`
- the final commit

It runs **before** these steps:

- the `ls-remote` race check at `:529`
- the guarded push at `:532`

A commit with new gate failures never reaches origin.

The worker's process group is already dead at this point (`attempt()` calls `kill_worker_group`
at `:600` before `publish`), so no straggler can race the gate checkout.

### 3.1 A clean, controller-owned checkout, by SHA

- **The SHAs.** The candidate is `C`, the controller's own final commit. The baseline is `sha`.
  Both are full SHAs the controller produced or recorded, never a ref name the worker could have
  moved.
- **The directory.** It is fresh on every run and is not a git worktree:
  `GATE_DIR="$(mktemp -d "$STATE/gate-work/$(slug "$REPO")-$JOB_PR-XXXXXX")"`. It is outside the
  worker's worktree and `WT_ROOT`. It is removed in `end_job`. Baseline runs get their own dir.
- **Materialising the tree.** The controller uses plumbing into a private index. It doesn't use
  `git worktree add` (which creates a `.git` file plus `$common/worktrees/<id>/` admin files), or
  `git archive` (which honours in-tree `export-ignore` and `export-subst`):

  ```bash
  gate_git read-tree --index-output="$GATE_DIR.index" "$C"
  GIT_INDEX_FILE="$GATE_DIR.index" gate_git --work-tree="$GATE_DIR" checkout-index -a -f
  ```

  The gate dir gets **no `.git`**, so a gate can't run git against the main clone. Decision 7
  assumes no gate needs one. The manifest's reserved `needs_git` key (§1) is where that would go
  later.
- **Ignored files.** Untracked or ignored files in the worker's worktree, such as a planted
  `node_modules/.bin/jest`, never reach the gate. Only committed content is checked out.

### 3.2 Sandbox, timeout and resource limits

`gates.py run` builds one command per gate run. The outer layer is a transient systemd scope
(cgroup v2 limits), then a timeout, then bubblewrap:

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
  gate exactly as it kills a worker (§4).
- **Per-gate timeout.** `timeout -k 30 <gate.timeout>`, for each run.
- **Job budget.** All candidate runs, baseline runs and installs share `budget`. `run_gates` stops
  starting runs once it is used up, and records `gate-timeout` for the remainder.
- **Host-wide gate lock.** `flock "$STATE/gates.lock"` around the whole gate run. Ticks for
  different repos then never run two `dotnet build`s at once on cachyos. The wait counts against
  the budget.
- **Fail closed.** If `bwrap` or `systemd-run --user` is missing, or the scope can't be created,
  this is an infra fault (§4). There is no unsandboxed fallback, and no `prlimit` fallback either:
  `RLIMIT_NPROC` is per user and would also throttle the controller and providers.
- **Telling infra from gate.** `--json-status-fd 3` (bubblewrap 0.5+) reports `child-pid` once the
  sandboxed process starts, then `exit-code`. No `child-pid` means bwrap itself failed (infra).
  Exit 126 or 127 from the child means the toolchain isn't bound into the sandbox (infra). The
  cgroup's `memory.events` `oom_kill > 0` marks a resource kill.

### 3.3 An env scrubbed of ssh keys and tokens

- `--clearenv` plus the explicit `--setenv` list above. No `SSH_AUTH_SOCK`, `GITEA_TOKEN`,
  `GH_TOKEN`, `ANTHROPIC_API_KEY`, `NPM_TOKEN`, `XDG_RUNTIME_DIR` or `DBUS_SESSION_BUS_ADDRESS`.
- `/home` is a tmpfs, so `~/.ssh`, `~/.config/tea`, `~/.config/pulse/gitea_token`,
  `~/.config/agent-pool/signing`, `~/.netrc`, `~/.git-credentials`, `~/.npmrc`, `~/.claude` and
  `~/.codex` don't exist inside the sandbox. `/run/user/<uid>` (the agent sockets) isn't mounted.
- **Toolchains under `$HOME`.** Dirs such as `~/.dotnet` or `~/.npm-global` are bound read-only,
  one directory at a time, from `AGENT_POOL_GATE_RO_BINDS`. `gates.py` refuses any entry that is
  `$HOME` itself, `~/.config`, or a parent of a `SENSITIVE` path.
- Decision 6 assumes no repo needs a registry token or extra env. A manifest can't add env vars
  (§1), and no token plumbing is built.

### 3.4 Network: none for gates, and how dependencies work without it

Gates run with `--unshare-all`, which includes `--unshare-net`: only a private loopback, no
egress. That is the point of D1. Code the worker could influence never runs with network.

Dependencies come from a controller-owned cache at `$STATE/gate-cache/<repo-slug>/`, with `npm/`,
`nuget/` and `composer/` subdirectories:

1. **Warm (network on, controller, no keys).** Warming is keyed by the `[[deps]].lockfile` blob at
   `sha`, the PR head before the worker. Lockfiles are protected (§1), so the baseline and the
   candidate always share that lockfile. When the blob differs from the one recorded in
   `gate-cache/<slug>/warmed.json`, `run_gates` checks out `sha` with the same plumbing as §3.1
   into a scratch dir. It then runs `warm` in a bwrap **with** network but still with
   `--clearenv` and a tmpfs home: `npm ci --ignore-scripts`, `dotnet restore`,
   `composer install --no-scripts --no-plugins`.
   - This is human-authored code (merged, or the PR's own commits before the worker), never
     worker output. It still never sees a key.
   - `dotnet restore` evaluates MSBuild from that tree. That is recorded as a risk (§7).
2. **Install (network off, sandbox).** `install` runs first inside each gate sandbox, against the
   read-only `/cache`: `npm ci --offline`, `dotnet restore --locked-mode` with
   `NUGET_PACKAGES=/cache/nuget`, and `composer install`, which can only resolve from
   `/cache/composer` because there is no network.
   - Lifecycle scripts may run here, because there's no network and no key.
   - A package missing from the cache can't be the worker's doing, because lockfiles are
     protected. It is an infra fault.

Scoping the network to "the npm registry only" would need a filtering proxy. This plan avoids
needing one: worker-influenced code gets no network, and human code gets plain network but no
credentials.

### 3.5 Baseline-relative gates: "no new failures"

Decision 3: fixes are pushed even when a gate was already red. What blocks a push is a **new**
failure, meaning one the worker's change introduced.

**Order.** `run_gates` runs every selected gate at the candidate `C` first. If all are green, the
result is `pass` and no baseline runs at all. For each gate that is red at `C`, it then runs the
same gate at the baseline `sha`, within the remaining budget. Baseline results are cached at
`$STATE/gate-baseline/<slug>/<sha>__<manifest blob>__<gate>.json`, so a re-gate or a later
attempt on the same PR head doesn't pay for them twice.

**"New failure" per gate**, set by the manifest's `compare`:

| `compare` | Candidate red counts as a new failure when | Notes |
|---|---|---|
| `exit` (default) | baseline was green (rc 0) | If both are red, the gate is "red before and after". The pool can't see inside an `exit` gate, so the comment says so, and suggests `junit` or `lines`. It counts as pre-existing, not new. |
| `junit` | a test id (`classname` + `name`) is failed or errored at `C` and wasn't failed or errored at `sha`. This includes a new test that fails. A test that **passed** at `sha` and is **absent** at `C` also counts. | A deleted passing test is treated as a new failure. That's the "worker weakens the tests" hole, closed for junit gates. |
| `lines` | a diagnostic key (the `key` regex's named groups, joined) occurs more times at `C` than at `sha` | A multiset comparison, so line-number churn from unrelated edits doesn't count when the key leaves line numbers out. For compilers and linters: `tsc`, `dotnet build`, `pint --test`, `eslint`. |

- **Timeout and resource kills.** A timeout or OOM at `C` is a new failure unless the same gate
  also timed out or was killed at `sha`.
- **Missing baseline.** If the baseline couldn't run (budget exhausted, or its own infra fault),
  "no new failures" can't be shown. The result is `gate-timeout` or `infra`, never a push.
- **Pre-existing red.** The PR comment's gate section lists every gate that was red at `sha` and
  still red at `C`, with its failures. The commit status for `C` is `failure` (§4.5), so a
  pre-existing red never auto-merges, even though the fixes land.

### 3.6 Output capture

- The runner, not the gate, owns both fds. Each gate run's stdout and stderr go to **one** file in
  arrival order:
  `$RUNS/gate-$JOB_PR-${ATTEMPT:0:8}-<name>-<cand|base>.log`. The runner does
  `stdout=f, stderr=f` in `subprocess.run`, so no `2>&1` appears anywhere, in worker or manifest.
  The file is capped at 10 MiB with a "[truncated]" marker. Exit code, duration, whether the
  timeout or an OOM kill fired, and the parsed junit or `lines` keys go to
  `gate-…-<name>-<cand|base>.json`.
- **What gets posted.** For each gate: name, argv, candidate result, baseline result if it ran,
  and duration. For a gate with new failures, also the new failures and the last 60 lines of its
  candidate log, in a `<details>` block.
  - Every line passes through `report.py`'s `leaks_secret` first. A matching line is replaced with
    `[redacted: token-shaped]`.
  - Absolute host paths (`$STATE`, `$HOME`, `$GATE_DIR`) are rewritten to `<state>`, `<home>`
    and `/work`, matching the "no local paths in the report" rule.
  - This is a new `report.py sanitize --file F` subcommand, so there is one secret scanner.

---

## 4. How results flow through publish, verify, the claim, Gitea and the merge loop

### 4.1 The resolve publish sequence

`attempt()` and `publish()` for a resolve job, in order:

1. The worker exits or is killed. `ckpt_stop`, `watch_stop`, `kill_worker_group`.
2. `still_held`, or `VERDICT=lost`. Then the final checkpoint (§2.5).
3. `classify.py` runs as today.
4. `report.py resolve` validates the worker's report. The worker's marker must name
   `head=<sha>`, the head it was given. It can't know the final head, because it doesn't commit.
5. `worker_head` must still equal `sha` (§2.2).
6. `stage_tree strict` (§2.2). If the tree equals `sha`'s and `fixed > 0`, that's
   `fail:the resolver claims N fix(es) but changed nothing`. If the tree changed and `fixed = 0`,
   that's `fail:the worker changed files but its marker claims no fixes`.
7. The final commit `C`, signed, on `refs/agent-pool/final/$ATTEMPT` (§2.7).
8. `run_gates` at `C`, with baselines at `sha` as needed (§3.5). It writes the receipt.
9. `still_held`, or `PUB=lost`.
10. Gate result: new failures, protected or rejected paths, timeout or resource give `fail:`.
    Infra gives `gateinfra:`. `pass`, `pass-preexisting` and `none-needed` carry on.
11. `report.py resolve --set-head C` rewrites the marker's `head=` to `C`. The marker is then
    controller-written in effect, so `marker.py`'s format and `pr-loop.sh` don't change.
12. The `ls-remote` race check, the `MAIN` config checksum, then
    `guarded push C:refs/heads/<headref>`.
13. The commit status `agent-pool/gates` on `C` (§4.5).
14. `comment_file`, then the published mark.
15. `verify()`.

For `fixed = 0` and an unchanged tree, steps 6 to 13 are skipped, as today: nothing is committed,
gated or pushed.

### 4.2 The receipt

`run_gates` writes one write-once receipt per attempt at
`$STATE/gates/<slug>__<pr>__<attempt_id>.json`, through `poolstate.save`, and refuses to overwrite
an existing one:

```json
{"version": 1, "attempt_id": "<gating attempt>", "work_attempt": "<Agent-Attempt of C>",
 "provider": "claude", "model": "opus", "pr": 7,
 "base_sha": "...", "pr_head": "<sha>", "head": "<C>",
 "manifest": {"source": "base|override", "blob": "<sha>"},
 "result": "pass|pass-preexisting|none-needed|gate-fail|gate-timeout|gate-resource|rejected|infra",
 "gates": [{"name": "client", "argv": [...], "cand": {"rc": 1, "secs": 212},
            "base": {"rc": 1, "secs": 198}, "new_failures": [], "preexisting": ["Foo.test x"]}]}
```

`attempt_id` and `work_attempt` differ only for an infra re-gate (§4.4). It also writes a copy
indexed by head at `gates/by-head/<slug>__<pr>__<C>.json`, which `verify()` reads.

### 4.3 Fencing

- The gate run happens inside the current attempt. `watch_start` watches the gate's process
  group, so a superseded attempt's gates are killed.
- `still_held` is checked after `run_gates` returns. If the claim was lost, `PUB=lost`: nothing is
  pushed or posted, and `run_job` takes its existing `lost` branch (`:678`).
- The push itself still goes through `guarded` (`:532`). `publish` pushes `C` only if the receipt
  for `C` names the current `$ATTEMPT`. A late receipt from a superseded attempt can never vouch
  for a newer attempt's push.
- Checkpoint writes are fenced by claim and deadline (§2.5). Stale holders' checkpoints are never
  pushed (§2.7).

### 4.4 `verify()`, `derive_job()` and the infra re-gate

- In `verify()` (`:290-339`), for `r_fixed > 0`, after the fast-forward check at `:329`, three
  checks are added. If any fails, it returns `fail:no signed, gated pool commit at $newsha`:
  - `gates/by-head/…__$newsha.json` exists, and its `result` is `pass`, `pass-preexisting` or
    `none-needed`.
  - `sign_git verify-commit "$newsha"` passes against `allowed_signers`, and the committer is the
    pool identity.
  - `$newsha`'s `Agent-Attempt` trailer equals the receipt's `work_attempt`.
- `derive_job()` (`:344-361`) settles a resolve through `verify`, so a resolve pushed without a
  controller commit and gate run is never settled. That covers a legacy `pr-loop.sh` run and a
  hand push. It is re-derived as a review instead (its head no longer equals the review head),
  which is the existing behaviour for a moved head.
- **Infra requeue keeps the work (decision 5).** On `gateinfra:`, `C` stays on
  `refs/agent-pool/final/<attempt>`, and the resume pointer has `final: true` and the report path.
  On the next tick that claims the job, `prepare_worktree` checks the pointer as in §2.6 (same
  `sha`, same review head, signature, ancestry). It then **skips the provider**: it re-validates
  the saved report, runs `run_gates` on that exact `C`, and continues at step 9 of §4.1. A sandbox
  hiccup then costs no provider run. The receipt records the new gating attempt as `attempt_id`
  and the original as `work_attempt`.
- **Status repair.** If posting the status fails after a successful push (step 13), the next
  tick's `derive_job` settles the head from its receipt and re-posts the status from it.

### 4.5 The commit status and `pr-merge.sh`

**The status.** `gitea-pr.py set-status --repo R --sha C --context agent-pool/gates --state S
--description D [--target-url U]` posts to `POST /repos/{owner}/{repo}/statuses/{sha}`. The
controller posts it on `C` immediately after the push. Gitea needs the commit to exist first, and
the controller only posts on commits it has already gated.

| State | When | Description |
|---|---|---|
| `success` | receipt `pass` or `none-needed` | "all N gate(s) green" or "no gate applies to the changed paths" |
| `failure` | receipt `pass-preexisting`: pushed with no new failures, but some gate red before and after | "no new failures; red before this change: client, net" |
| `pending`, `error` | never posted | Nothing is pushed on any other result, so there is no pool commit to mark. To `pr-merge.sh`, an absent status is the same as a non-`success` one. |

**The Gitea side:**

- A dedicated Gitea user, for example `agent-pool`, has the pool email as its verified email and
  `pool_ed25519.pub` as a verified ssh key. Gitea then shows pool commits as "Verified" for that
  user. The account needs no repo permissions. It is an identity only, so the key authenticates
  to nothing useful.
- Pushes and statuses still use the controller's existing ssh agent and token.
- Gitea's `require_signed_commits` branch protection is **not** turned on for PR branches. It would
  also reject humans' unsigned pushes. `pr-merge.sh` enforces pool signatures instead.

**The `pr-merge.sh` change.** The `TODO: add required-status-context gates` at line 7 is replaced
by a check inside `gitea-pr.py merge` itself. The check then runs against the same API snapshot as
its existing `--expected-head` test, with no gap between check and merge. `pr-merge.sh` passes the
new flags:

```bash
merge_out="$(python3 "$ADAPTER" merge --repo "$REPO" --pr "$pr" \
  --expected-head "$sha" --base "$BASE" --style "$STYLE" \
  --require-context "${PR_MERGE_REQUIRED_CONTEXT:-agent-pool/gates}" \
  --status-creator "$PR_MERGE_STATUS_CREATOR" \
  --pool-email "$PR_MERGE_POOL_EMAIL" \
  --allowed-signers "${PR_MERGE_ALLOWED_SIGNERS:-$HOME/.config/agent-pool/signing/allowed_signers}" 2>&1)"
```

`cmd_merge` adds these rules, all fail-closed, after its head, base and mergeable checks:

1. **Every pool-looking commit is really the pool's.** It fetches
   `GET /repos/{o}/{r}/pulls/{n}/commits`. A commit looks like a pool commit if its final
   paragraph has any `Agent-*` trailer, or its committer email is the pool email. Each such commit
   must pass `ssh-keygen -Y verify -f <allowed_signers> -I <pool email> -n git`, run on the
   `verification.payload` and `verification.signature` Gitea returns. Gitea's own
   `verification.verified` must also be true. Otherwise the merge is refused with "commit X claims
   pool authorship but is not signed by the pool key", and `pr-merge.sh` turns that into
   `needs-human`.
2. **A pool head needs green gates.** If the head commit is a pool commit, the latest
   `agent-pool/gates` status on the head (`GET /repos/{o}/{r}/commits/{sha}/statuses`) must be
   `success`, and its `creator.login` must be `PR_MERGE_STATUS_CREATOR`. Otherwise the merge is
   refused with "agent-pool/gates is <state or missing> at <sha>: <description>".
3. **A human head is not gated by the pool in v1.** If a human pushed after the pool, or the pool
   never committed, the status isn't required. Rule 1 still checks any earlier pool commits.
   Requiring the status on every head needs gates on review jobs (§6 step 15). That is an open
   question (§7).

The header comment's phase description gains "pool-authored heads need a signed commit and a
green agent-pool/gates status".

### 4.6 What the comment carries

`publish` builds the posted comment as:

1. the worker's report
2. a controller-written `### Gates (run by the pool controller)` section. It covers new failures,
   pre-existing red at `sha`, and green gates.
3. `<!-- agent-pool-gates:v1 head=<C> manifest=<blob> result=<result> -->`
4. the resolve marker with `head=<C>`, kept as the last line

`report.py` parses only the last `pulse-resolve` marker, so nothing about marker parsing changes.
The gate marker is informational. The authorities are the local receipt and the signed commit.

### 4.7 Failure taxonomy

`publish` returns one new `PUB` value, `gateinfra:<why>`. The other gate outcomes reuse `fail:`.

| Class | Detected by | Push | Status | Label (`finish_job`) | Provider cooldown | Setup fault | Work kept on |
|---|---|---|---|---|---|---|---|
| **pass** | every selected gate rc 0 at `C` | yes | `success` | `done` after `verify` ok | `cooldown.py clear` (`:619`) | no | the PR branch |
| **none-needed** | `gates.py select` → none (docs-only) | yes | `success` | `done` | clear | no | the PR branch |
| **pass-preexisting** | some gate red at `C`, no new failures against `sha` (§3.5) | **yes** | `failure` | `done` (the comment lists pre-existing red; the status blocks automerge) | clear | no | the PR branch |
| **rejected** | `stage_tree strict` (§2.2): protected path, symlink, mode change, size | no | none | `needs-human` (`fail`) | none | no | `attempts/<id>` (drop-mode checkpoints) |
| **gate-fail** | new failures at `C` | no | none | `needs-human` (`fail`) | none, and strikes are **not** cleared | no | `final/<id>` |
| **gate-timeout** | `timeout` fired at `C` and not at `sha`, or the budget ran out before a needed baseline | no | none | `needs-human` (`fail`) | none | no | `final/<id>` |
| **gate-resource** | OOM or `TasksMax` at `C` and not at `sha` | no | none | `needs-human` (`fail`) | none | no | `final/<id>` |
| **infra** | bwrap/systemd-run missing or failing, no `child-pid`, child rc 126/127, manifest unreadable or invalid at `BASE_SHA`, cache warm or offline install failure, checkout failure, signing failure, `MAIN` config checksum mismatch, disk full | no | none | `ready` (requeue) | **none** for the provider | **yes**, `setup_fault gates "<why>"`, so the tick exits 2 | `final/<id>`, re-gated next tick without a provider (§4.4) |
| **lost** | `still_held` false after gates | no | none | untouched | none | no | whatever was fenced in (§2.5) |

Notes on the rules:

- **Gate failures are not limits.** They take the `fail:` path, never `fail-nomarker:`, so the
  fast-fail rule at `:629-631` can't turn a quick red gate into a cooldown.
- **The classifier's verdict still comes first.** In `attempt()`, a `cls` of `limit`, `setup` or
  `timeout` is checked before a plain `fail` (`:624-628`). A provider that hit a limit mid-job
  usually left no valid report. It is cooled down, and the next provider **resumes from its final
  checkpoint** (§2.6) instead of starting over.
- **Infra is handled before `cls`.** `attempt()` maps `gateinfra:*` to `VERDICT=requeue` before
  the `cls` case. Falling through to the next provider would hit the same broken sandbox and burn
  another full `WORKER_TIMEOUT`.
- **Stop claiming while gate infra is broken.** `cooldown.py fault --provider gates` is recorded,
  and `select_providers` is extended: while `faults/gates.json` is newer than the last successful
  gate run, `job_providers resolve` returns nothing. Resolve jobs are then skipped (not claimed)
  until a person fixes the sandbox. Review jobs keep running. The same applies to
  `faults/signing.json`.
- **The published mark.** Nothing is published on any non-push path, so `published_mark` (L4) is
  never written and a later stale claim keeps today's strike rules.

### 4.8 Deadline and timing (decision 4)

The claim's `expected_deadline_at` must cover the worker, the gates, and the commit, push and post
steps. The startup check at `:707-708` becomes:

`WORKER_TIMEOUT + AGENT_POOL_GATE_BUDGET + 120 < AGENT_POOL_DEADLINE_SECS`

The defaults become **`WORKER_TIMEOUT=1800`, `AGENT_POOL_GATE_BUDGET=1200`,
`AGENT_POOL_DEADLINE_SECS=3300`**: 1800 + 1200 + 120 = 3120, leaving 180s of margin. The 120s
covers the final checkpoint, strict stage, signing, push, status and comment. Why this split is
right:

- **Checkpointing makes a short worker timeout cheap.** The old 2400s worker was sized so a run
  that was nearly done didn't lose everything at the cutoff. With a checkpoint every 300s and a
  final checkpoint at the cutoff, an 1800s cutoff loses nothing. The next provider, or the next
  tick, resumes. Rate limits work the same way: a run cut off by a limit is a pause, not a loss.
- **The gate budget has to cover baselines.** With decision 3, a red gate costs a second run at
  `sha`. 1200s covers one install plus a candidate and a baseline run of the slowest current gate
  (AMPB `clientv2`, to be measured in §6 step 11.2). Baselines run only for gates that are red at
  `C`, and they're cached per PR head, so the usual cost is the candidate run alone.
- **A shorter deadline means faster recovery.** A crashed holder's claim goes stale after 55
  minutes, not longer. With checkpoints, its successor resumes rather than redoing the work.
- **An infra re-gate (§4.4) runs no provider.** It needs only the gate budget, well inside the
  deadline.

---

## 5. The worker side: `policy.py`, adapters and prompts

### 5.1 What `policy.py` can drop

The worker policy becomes file edits through the CLI's own tools plus read-only git. **There is no
exception for `git add` or `git commit` any more (decision 1).**

#### Kept

| Job | Allowed |
|---|---|
| review | `git status`, `git diff`, `git log`, `git show`, with the existing vetted options (`GIT_SPECS` for those four only). Native `Read`, `Grep` and `Glob`, scoped (below). `Write(<report>)`. |
| resolve | Everything review has, plus `Edit` and `Write` on `<wt>/**` (still excluding `.git`, `.cursor`, `.grok`, `.claude`, the context file and `.agent-pool/`), and `Write(<commit-msg file>)`. |

The resolve prompt's `git rev-parse HEAD` goes away. The marker names `__SHA__`, and the controller
rewrites it (§4.1 step 11).

#### Dropped

| Dropped | Where today | Why it can go |
|---|---|---|
| `GATES`, `GATE_SHELL`, the gate branch of `segment_ok` | `policy.py:123-125`, `:241-245`, `:223-226` | The controller runs gates. |
| `git add`, `git commit` (all forms), `COMMIT_SHELL`, `add_positional` | `:205-207`, `COMMIT_SHELL` | The controller stages and commits (§2). This closes `git commit -F ~/.config//tea/config.yml` and `git add ././` (10511) by removing the commands, not by patching their arguments. |
| `TOOL_SPECS` (`cat ls head tail wc grep rg`) and their `READ_SHELL` globs | `:105-122`, `:240` | The CLIs' own Read, Grep and Glob replace them. Without `head`/`tail`, a pipe has nothing to feed. |
| `git rev-parse`, `ls-files`, `grep`, `blame` from `GIT_SPECS` and `READ_SUBS` | `:90-103`, `:238` | Not in the minimal set. |
| `python3 <adapter> head\|comments\|threads` | `:212-222`, `:288` | The controller already writes the comments into `.agent-pool-context.md` (`write_context`, `:556-568`). It will also write `threads` and the PR head. The worker never touches the adapter, so it never needs a process that reads `~/.config/pulse/gitea_token`. |
| Pipes, `&&`, `\|\|`, `;`, newlines as separators | `tokenize`, `SEPARATORS` | A worker command is exactly one simple command. Any operator character denies it outright, so the segment logic collapses to "one segment or deny". |
| `--hidden`, `--no-ignore` and every other tool option | `TOOL_SPECS` | The tools are gone. |
| The deny-list entries for the dropped tools (`rg *--pre*`, `rg *-z*`, `git grep *-O*`, `tail *-f*`, `python3 -c*`, `node*`, `npx*`, `bash*`, `sh *`, `env*`, `eval *`) | `DENY_SHELL :257-261`, `CURSOR_DENY :270-273` | Unreachable under a pure allowlist. The push, `reset --hard` and `merge` denies stay, per the owner decision, and `git add*`, `git commit*`, `git checkout*`, `git stash*` and `git update-*` are added as explicit denies. |

#### Added: a post-expansion check in a PATH shim

`AGENT_POOL_HOME/workerbin/git` is put first on the worker's `PATH`. It calls `policy.py check
--argv` on its **real argv**, which is after the shell has done brace, glob, tilde and quote
expansion, and then execs `/usr/bin/git`. The CLI rules (glob or prefix) remain the first line,
and the shim is the second. The allowlist only permits commands that start with the word `git`,
so a worker can't reach `/usr/bin/git` directly. The shim allows only `status`, `diff`, `log` and
`show`.

#### Bypass classes this closes

| Class (review) | How it is closed |
|---|---|
| Brace expansion, e.g. `rg {-,}-pre=sh`, `git log {-,}-output=<path>` (10511 #1) | `rg` is gone. The shim sees `--output=<path>` after expansion and denies it. The raw check also rejects unquoted `{`, `}`, `*`, `?`, `[` and a leading `~`. |
| Redirection, here-strings, `<(...)` (10507 #1, 10511) | Any operator character denies the whole command. Nothing legitimate needs one any more. |
| `2>&1` | Never needed. The runner captures stderr (§3.6), and the CLIs capture the worker's. The "narrow `2>&1` allowance" 10511 suggested is **not built**. |
| Interpreters: `python3`, `node`, `npx`, `sh`, and repo scripts run by `npm run`/`just`/`composer`/`dotnet` (D1) | No allowed command executes code. The only interpreter left was `python3 <adapter>`, and it's gone. |
| Pipes into an executor (`\| sh`, `\| xargs`) | No pipes. |
| Recursive reads of a parent folder (`grep -r token ~/.config`, `rg --hidden --no-ignore BEGIN ~`) (10511 #2) | `grep`/`rg` are gone. Native Read, Grep and Glob are scoped by the Claude hook (`hook()`, `write_allowed`) to `<wt>`, the per-job dir and the context file. They're no longer just checked against `sensitive()` fragments. |
| Unnormalised and wildcard paths (`~/.config//tea`, `/./`, `~/.s*/config`) (10511 #2) | Paths are normalised with `os.path.normpath(os.path.realpath(...))` before the scope check. Shell wildcards are rejected raw and re-checked post-expansion by the shim. |
| Option values naming credentials (`git commit -F <secret>`) (10511 #2) | `git commit` is gone. |
| `git add ././`, `git add` of tool config (10511, S3) | `git add` is gone. The controller's strict stage refuses protected paths anyway (§2.2). |
| Commit hooks, signing config, forged authorship | Workers don't commit. Controller commits run no hooks, read no global config, and carry controller-set trailers (§2.1, §2.4). |
| `git difftool`, `--ext-diff`, `--textconv`, pagers, `-c`/`-C`, `GIT_PAGER=` (10507, 10511) | Still denied by `GIT_SPECS`. With `GIT_CONFIG_GLOBAL=/dev/null` no external diff or textconv driver even exists. |
| Network egress and pushes to an explicit URL from a gate script (D1) | The worker runs no gate. The gate sandbox has no network and no key. |
| Token reads through the adapter process | The worker no longer runs the adapter. |

`SENSITIVE`, `credential_globs()` and `report.py`'s `leaks_secret` stay. Those are the
defence-in-depth for native Read and for posted text.

### 5.2 Impact on the adapters and their permission files and hooks

These changes apply to all providers:

- **`spawn_worker` (`:398-406`)** adds the following to its `env`:
  - `-u SSH_AUTH_SOCK -u GITEA_TOKEN -u GH_TOKEN -u NPM_TOKEN -u GNUPGHOME -u GPG_AGENT_INFO`
  - `PATH="$AGENT_POOL_HOME/workerbin:/usr/bin:/bin"`, so the shim comes first. Provider binaries
    are already launched by absolute path from `bin_for`.
  - `GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1`
  - `GIT_CONFIG_COUNT=2`, with `remote.origin.pushurl` (existing) and `core.hooksPath=/dev/null`.
    No `user.name` or `user.email` is needed, because workers don't commit.
  - The CLIs keep their own auth (for example `~/.claude/.credentials.json`). "No keys" means no
    ssh, signing or Gitea keys. Model-provider auth is the CLI's own business, and its files are
    still denied to the worker's Read.
- **`ckpt_start`/`ckpt_stop`** wrap the worker next to `watch_start` (§2.5).
- **`write_context` (`:556-568`)** runs for every provider. It adds `threads` JSON, the PR head
  SHA, the list of gates the controller will run, and on resume the "Resuming" section (§2.6).
- **`exclude_tool_config` (`:219-229`)** adds `/.agent-pool/` to `info/exclude`'s list. The
  protected set (§1) replaces the `publish` path check at `:527`.
- **The per-job dir.** `$RUNS/job-<pr>-<attempt8>/` holds `report.md`, `commit-msg.txt` and
  `dirty`.

| Adapter | Today | After |
|---|---|---|
| **Claude** (`build_cmd :250-260`) | `--allowedTools` with ~40 Bash globs including the gates and the adapter. `--settings` PreToolUse hook running `policy.py hook`. `--add-dir "$RUNS"`. | `--allowedTools`: `Read Grep Glob Write(//<report>)`, `Bash(git status)`, `Bash(git status *)` and the same for diff, log and show. Resolve adds `Edit(//<wt>/**) Write(//<wt>/**) Write(//<commit-msg>)`, but no `Bash(git add*)` or `Bash(git commit*)`. `--disallowedTools` covers push, reset, merge, add, commit, `git -c*`, `git -C*`, `*--output*`, `.git/**` writes and credential reads. The `--settings` file keeps the PreToolUse hook. `hook()` scopes Read, Grep and Glob paths (normalised) to `<wt>`, the per-job dir and the context file. It adds a `PostToolUse` `Edit\|Write` hook that touches `dirty` for step-boundary checkpoints. `--add-dir` narrows from all of `$RUNS` to the per-job dir. |
| **Cursor** (`.cursor/cli.json`, written by `attempt :589-592`) | `Shell(<prefix>)` for every `READ_SHELL`, `GATE_SHELL` and `COMMIT_SHELL` prefix. Prefixes can't constrain arguments (recorded residual). | `Shell(git status)`, `Shell(git diff)`, `Shell(git log)`, `Shell(git show)` only. `Read(**)` narrows to `Read(<wt>/**)` and `Read(<context>)`. Resolve `Write` covers `<wt>/**` and the commit-msg file. The argument residual is covered by the PATH shim, which checks post-expansion argv whatever the prefix allowed. If Cursor's `hooks.json` `beforeShellExecution` and `beforeReadFile` are confirmed live (§6 step 11), `policy.py cursor-hooks` emits `.cursor/hooks.json` calling `policy.py hook --format cursor`. `.cursor/hooks.json` is added to `info/exclude` and the protected set. Checkpoints are timer-only. |
| **Grok** (`build_cmd :266-272`) | `--allow`/`--deny Bash(<glob>)` for the full read, gate and commit set. | The same short glob list as Claude, through `--allow`. `Read` becomes `Read(<wt>/**)` and `Read(<context>)`. Grok has no hook, so the shim is its post-expansion check, and its checkpoints are timer-only. |
| **agy** (`build_cmd :273-278`) | Review in `--mode plan` with no commands, already context-file driven (`review.agy.txt`). Resolve only with `AGY_AUTO_APPROVE=1` and `--dangerously-skip-permissions`. | **Review only (decision 8).** Review is unchanged. Resolve is removed: `--dangerously-skip-permissions` runs any command with the user's ssh agent, so "workers get no keys" can't hold outside a jail. `job_providers` (`:198-205`) drops agy for resolve unconditionally, and `AGY_AUTO_APPROVE` is retired with a SETUP FAULT if set. Resolve comes back only through §6 step 14. |
| **Codex** (`build_cmd :279-282`) | Not in any default order. The `workspace-write` sandbox has no network, so its adapter reads already failed. | Fits the new model better than before. It reads the context file, not the adapter, runs no gate and makes no commit. No code change beyond the prompt. It's still not in the default order. |

### 5.3 Prompts (`skills/pr-loops-common/prompts/`)

- **`resolve.generic.txt`**:
  - Step 1 no longer says AGENTS.md names gate commands for the worker to run.
  - Step 2 reads findings and threads from `__CONTEXT__` instead of running the adapter.
  - Step 5 becomes: "Do not run builds, tests or linters, and do not commit; you cannot. Edit the
    files only. When you finish, write a proposed commit message (subject line, blank line, short
    body) to `__COMMIT_MSG__`. The pool controller commits your changes, runs `__GATES__` on them,
    and refuses to push if they add a new failure. Do not edit `__PROTECTED__`."
  - "State the gate result" is removed from step 6, because the controller writes that section.
  - The Fixed section cites files and lines, not commit SHAs.
  - The marker's head instruction becomes: "`head=__SHA__` exactly; the controller fills in the
    final head."
  - A resume paragraph: "If `__CONTEXT__` has a Resuming section, earlier work is already in your
    tree. `git diff` shows all of it. Continue from it, and account for every finding in your
    report."
- **`review.generic.txt`** step 1 reads comments from `__CONTEXT__`.
- `render_prompt` (`:570-576`) adds `GATES=`, `PROTECTED=` and `COMMIT_MSG=`.

---

## 6. Migration order

Every step keeps `verify-lease.sh`, `verify-providers.sh` and `verify-merge.sh` green at that step.
Two orderings matter:

- **Gates move to the controller (step 6) before the worker loses them (step 10).** The other way
  round would leave a window where resolve pushes are ungated.
- **The controller commits (step 6) before the worker loses `git add` and `git commit`
  (step 10).** Between those steps, a worker that still commits does no harm. `stage_tree` reads
  files, not the worker's HEAD, and builds `C` on `sha`. The `worker_head == sha` assertion
  (§2.2) is switched on in step 10.

**Step 0. Land #2 first.** Clyde finishes round 4 (10511) on #2, including the brace-expansion
blocker and finding 2. Those fixes still matter for review jobs and for the shim's raw check. #2
should **not** add the `2>&1` allowance. One cheap prompt line ("do not append `2>&1`; output is
captured") is fine.

**Step 1. `scripts/gates.py` load/validate/select/protected/compare, plus a sample manifest.**
New `agent-pool/tests/verify-gates.sh` (unit, offline):

- `load` reads only the base blob. A different `gates.toml` in the worktree is ignored, and the
  test asserts the receipt's blob SHA equals the base's.
- The override file wins over the base file.
- Validation rejects each of these: a shell string, `argv[0]=sh`, an unknown key, `cwd=../x`,
  timeout above budget, an `argv[0]` outside `GATE_RUNNERS`, `needs_git = true`, an `env` table,
  `compare="junit"` with no `report`, and a `lines` key that doesn't compile.
- `select` returns `none` for a docs-only diff and the right gates for a mixed diff.
- `protected` flags `.agent-pool/gates.toml`, `.gitattributes`, `.gitmodules`, a gitlink, a
  lockfile and a `protect` entry.
- `compare` covers each mode with fixture results:
  - `exit`: green→red is new, and red→red is pre-existing.
  - `junit`: a newly failing test is new, a still-failing test is pre-existing, a deleted passing
    test is new, and a new failing test is new.
  - `lines`: an extra occurrence of a key is new, and a moved line with the same key is not.

**Step 2. Sandbox runner: `gates.py run`.**
Cases in `verify-gates.sh`. The suite prints `SKIP (bwrap missing)`, counted separately and never
silently passed, when `bwrap` or `systemd-run --user` is absent. The fixture gate is a small
script in a fixture repo.

- With fixture `HOME`/`.ssh/id_test`, a fixture `~/.config/agent-pool/signing/pool_ed25519`,
  `SSH_AUTH_SOCK` and `GITEA_TOKEN` set in the controller's env, the gate sees none of them (it
  dumps `env` and `ls -a ~ ~/.config`).
- A connect to a TCP listener the test opened on the host's 127.0.0.1 fails from inside the
  sandbox.
- A write outside `/work` and `/tmp` fails.
- A gate printing to both fds gets both into one log, in order, with no `2>&1` anywhere.
- `sleep` past the timeout gives `gate-timeout`.
- A memory hog over `MemoryMax=64M` gives `gate-resource`.
- A missing `argv[0]` gives `infra` (127).
- A bwrap that can't start (`AGENT_POOL_GATE_SANDBOX=/nonexistent`) gives `infra`.
- `AGENT_POOL_GATE_RO_BINDS=~/.config` is refused.
- A token-shaped line is redacted by `report.py sanitize`, and host paths are rewritten.

**Step 3. Controller git: `gate_git`, `sign_git`, `stage_tree`, `gate_checkout`, commit messages
and trailers.**
`verify-providers.sh` gets a new section, "controller commits". The fixture signing key is a
throwaway ed25519 key under the test's `$TMP`.

- **Staging and the protected set.**
  - A worktree change adding `.gitattributes` with `* filter=evil`, while a fixture
    `~/.gitconfig` defines `filter.evil.clean="touch $TMP/pwned"`, leaves `pwned` absent, and
    strict mode rejects the path.
  - Strict mode rejects each of: a symlink, a `chmod +x` on a tracked file, a new `100755` file, a
    gitlink, a 6 MiB blob, and `.agent-pool/gates.toml`. Drop mode keeps the rest and lists the
    dropped paths in `Agent-Dropped:`.
- **Git environment and tamper checks.**
  - A `pre-commit` hook in `MAIN/.git/hooks`, and a worktree `.git` file rewritten to point
    elsewhere, have no effect.
  - `GIT_DIR=/elsewhere` exported in the tick's env is ignored.
  - A changed `MAIN/.git/config` checksum gives an infra fault and no push.
- **Signing and trailers.**
  - The final commit verifies with `git verify-commit` against `allowed_signers`. A commit signed
    by another key does not.
  - A worker `commit-msg.txt` containing `Agent-Provider: human`, `Co-authored-by: x`, an HTML
    comment and a token-shaped line yields a commit whose trailers come from the claim record and
    whose body has none of those.
  - An empty `commit-msg.txt` gives the fallback subject.
  - A missing or `0644` signing key gives `SETUP FAULT [signing]` and no resolve claims.
- **The gate checkout.** The gate dir has no `.git`, and has none of the worker worktree's
  untracked or ignored files.

**Step 4. Checkpoints and resume: `ckpt_start`/`ckpt_stop`, the resume pointer, and
`prepare_worktree` resume.**
New stub behaviours in `verify-providers.sh`, with `AGENT_POOL_CHECKPOINT_SECS=2`:

| Behaviour | Asserts |
|---|---|
| `resolve-slow` (edits a file, sleeps, edits another) | Two or more checkpoints on `refs/agent-pool/attempts/<id>`, each signed, each with `Agent-Checkpoint: n`. No checkpoint when the tree didn't change. |
| `resolve-cutoff` (edits, then exceeds `WORKER_TIMEOUT`) | A final checkpoint holds both edits. The next provider's worktree starts with them (`git diff` vs `sha` shows them), and its context file has a Resuming section. Its final commit has `Agent-Resumed-From:`. |
| `resolve-limit` (edits, then prints a rate-limit error) | The provider is cooled down, and the next provider resumes from the checkpoint. |
| a human pushes to the PR between attempts | The pointer is discarded, and the next attempt starts fresh from the new head. |
| `steal` mid-run, then the stale holder keeps editing | The stale holder writes no checkpoint after the steal. Its post-steal edits never appear in the successor's tree, and nothing it made is pushed. |
| a run past `expected_deadline_at` (clock fixture) | No checkpoint is written after the deadline. |
| a tampered checkpoint (re-signed with another key) | Not resumed. |

**Step 5. Baseline-relative gates.**
Fixture gates in `verify-gates.sh` and `verify-providers.sh`:

- A gate red at `sha` and still red at `C`, with no new failures: **pushed**, receipt
  `pass-preexisting`, and the comment lists the pre-existing red.
- A gate green at `sha` and red at `C`: not pushed, `gate-fail`, `needs-human`.
- A junit gate where the worker deletes a passing test: `gate-fail`.
- A gate green at `C`: no baseline run happens (a sentinel proves it).
- A second attempt on the same `sha`: the baseline comes from the cache.
- The budget runs out before a needed baseline: `gate-timeout`, not pushed.

**Step 6. Wire it all into `publish`: the final commit, `run_gates`, receipts, the comment
section, the status, and the verdict mapping (§4.1).**
New stub behaviours in `verify-providers.sh`. The stub manifest lives in the bare origin's base
branch. The fake Gitea adapter records `set-status` calls.

| Behaviour | Asserts |
|---|---|
| `resolve-fix` with gate `true` | Pushed (`origin_head` moved to a signed pool commit whose parent is `sha`), `agent:done`, status `success` on that commit, the comment has the gate section and `agent-pool-gates:v1 … result=pass` before the resolve marker, the marker's `head=` is the pushed commit, and a receipt exists keyed by attempt. |
| gate `false` (red only at `C`) | `agent:needs-human`, `origin_head` unchanged, no status, the comment has the gate name and tail, no provider cooldown file, and `C` is on `refs/agent-pool/final/<id>`. |
| gate red at both | Pushed, status `failure` with "no new failures", `agent:done`. |
| gate sleeps past its timeout | `needs-human`, "timed out". |
| sandbox missing | `agent:ready`, `SETUP FAULT [gates]`, `TICK_RC=2`, no provider cooldown, no comment, and the next tick skips resolve jobs while reviews still run. |
| sandbox missing, then fixed | The next tick re-gates the kept `C` **without spawning a provider** (the stub's spawn counter is unchanged), then pushes it. |
| `resolve-gatefile` (worker edits `.agent-pool/gates.toml`) | `needs-human` and a sentinel proving no gate ran. |
| `resolve-gatescript` (worker edits `package.json`) | `needs-human`. |
| `resolve-symlink` | `needs-human`, "symlink". |
| `steal` during the gate | `lost`, no push, and the gate's process group is dead. |
| docs-only fix | `none-needed`, pushed, status `success`. |
| `fixed=0` | Nothing committed, gated or pushed (unchanged). |
| `fixed=1` with no file change | `fail`, "changed nothing". |
| status post fails after the push | The next tick re-posts it from the receipt. |
| startup check | `WORKER_TIMEOUT + GATE_BUDGET + 120 >= DEADLINE` makes the tick die at start. The new defaults pass. |

**Step 7. `verify()` and `derive_job()` require a passing receipt and a pool signature for
`fixed > 0`.**

- A resolve marker at the current head with no receipt isn't `settled`. It is derived as a review.
- A head with a receipt but an unsigned or foreign-signed commit isn't settled.
- With a receipt and a signature, it settles as today (the G6 path).

A unit test covers the receipt's write-once rule: a second write for the same attempt is refused.

**Step 8. Gitea status and `pr-merge.sh`.**

- `gitea-pr.py` gains `set-status`, `statuses`, `commits`, and the `merge` flags in §4.5.
- New cases in `skills/pr-loops-common/tests/verify-merge.sh`, using the fake API:
  - A pool head with status `success` from the pool creator merges.
  - A pool head with `failure`, no status, or a `success` from another creator is refused, and the
    PR goes `needs-human`.
  - A commit with `Agent-Provider:` but no valid pool signature (unsigned, or signed by another
    key) is refused.
  - A human head on top of a valid pool commit merges without the status.
  - The `TODO` line is gone, and `PR_MERGE_REQUIRED_CONTEXT` defaults to `agent-pool/gates`.

**Step 9. Prompts and context.**

- `write_context` adds threads, the head, the gate list and the Resuming section for every
  provider. `verify-providers.sh` extends `CONTEXT_DIFF_LINES` to assert threads are present for
  claude, cursor and grok.
- In the `verify-lease.sh` "prompt rendering" and `verify-providers.sh` "prompts" sections, the
  rendered resolve prompt contains `__GATES__`'s and `__COMMIT_MSG__`'s values. It contains none
  of `npm`, `2>&1`, `gitea-pr.py`, `rev-parse`, `git add` or `git commit`.

**Step 10. Shrink `policy.py`, add the shim, and drop add and commit.**

`verify-lease.sh` "worker permission policy", in both families:

- Every 10511 probe is denied: `rg {-,}-pre=sh foo`, `git log {-,}-output=/tmp/x HEAD`,
  `grep -r token ~/.config`, `cat ~/.config//tea/config.yml`, `cat ~/.s*/config`,
  `git commit -F ~/.config//tea/config.yml`, `git add ././`.
- Every former gate is denied in resolve: `npm test`, `npm run gate`, `just`, `dotnet test`,
  `composer test`.
- `git add src/a.php`, `git commit -m "fix: x"`, `git checkout -- .` and `git stash` are now
  **denied** in resolve.
- `python3 <adapter> head …` is now denied. Any `|` is denied.
- `git status`, `git diff origin/master...HEAD`, `git log -1 --format=%H` and `git show HEAD` are
  allowed.
- Native Read of `~/.config/agent-pool/signing/pool_ed25519` is denied.
- Shim cases run `workerbin/git` with expanded argv, such as `--output=/tmp/x` reached through
  braces, and expect exit 2 with no file created. `workerbin/git commit` exits 2.

Existing tests that asserted gates, adapter reads, `git add` or `git commit` as **allowed**
(`verify-lease.sh:320-330`, `verify-providers.sh:297`) are inverted, not deleted. The
`worker_head == sha` assertion in `publish` is switched on here.

**Step 11. Adapters, plus live checks on cachyos.**

`verify-providers.sh` adapter-shape cases:

- Claude's `--allowedTools` has no `npm`, `python3`, `rg`, `git add` or `git commit`, and its
  `--settings` has the PostToolUse hook.
- Cursor's `cli.json` has no gate or commit prefixes, and `Read` is scoped.
- Grok's `--allow` list matches.
- agy is never spawned for resolve even with `AGY_AUTO_APPROVE=1`, and a SETUP FAULT is logged.
- The stub's env dump shows no `SSH_AUTH_SOCK` or `GITEA_TOKEN`, shows
  `GIT_CONFIG_GLOBAL=/dev/null`, and shows `workerbin` first on `PATH`.
- A stub worker running `git log {-,}-output=$TMP/x` through a real `bash -c` creates no file.

Live checks on cachyos (manual, recorded in the PR):

1. Unprivileged `bwrap --unshare-all` works, since the CachyOS kernel needs user namespaces.
   `systemd-run --user --scope -p MemoryMax=… -p TasksMax=…` works from a systemd user timer
   context, not just an interactive shell. `--json-status-fd` is supported by the installed
   bubblewrap.
2. A real gate run on a scratch clone of one real repo (AMPB `clientv2` `npm run gate`, and one
   `dotnet build`), offline from a warmed cache, at both a candidate and a baseline, inside the
   budget. Record durations to confirm the 1200s budget.
3. Claude end to end on a scratch PR. The shrunk allowlist plus hook lets it read and edit. The
   PreToolUse and PostToolUse hooks and `--add-dir` work for real (also an open item from 10510).
   Checkpoints appear during the run.
4. Cursor: whether `hooks.json` `beforeShellExecution` fires in headless `-p` mode. If it doesn't,
   Cursor resolve relies on the shim.
5. Grok: whether its Bash tool inherits the env `PATH`, so the shim is reached.
6. **Signing on Gitea.** The `agent-pool` Gitea user exists with the pool email and the verified
   ssh key, and a pushed pool commit shows "Verified". `ssh-keygen -Y verify` succeeds on the
   `verification.payload` and `verification.signature` the PR-commits API returns. If the payload
   doesn't round-trip, `cmd_merge` instead fetches the head into a scratch bare mirror and runs
   `git verify-commit` there. The step records which path is used.
7. **Commit status.** `set-status` from the controller's token is visible on the PR, and
   `creator.login` matches `PR_MERGE_STATUS_CREATOR`.
8. Confirm a real resolve's comment renders the gate section, with no host paths and no secrets.

**Step 12. Docs and doctor.**

- `agent-pool-worker-pool.md` records D1 and the Oct 17 decisions (pointing here), and D2 as one
  host per repo.
- Remove "Gate commands run code the resolve worker can edit" from Open questions.
- Add the gate, checkpoint and signing knobs to the `prod-common.sh` header.
- When `doctor.sh` is built, it checks for these:
  - bwrap and systemd-run
  - a writable gate cache with a size cap
  - a stale `faults/gates.json` or `faults/signing.json`
  - the signing key's mode and its `allowed_signers` line
  - `refs/agent-pool/*` past retention

Steps 0 to 12 are the follow-up PR (§8). The next two steps are later PRs, each with its own
review.

**Step 13. Worker jail (bwrap for workers).** Each provider CLI runs inside a bwrap. Network stays
on, because the CLIs need their own APIs.

- **Bound read-write:** `<wt>` and the per-job dir.
- **Bound read-only:** the context file, toolchains, and the one CLI's own auth and config dir
  (for example `~/.claude`).
- **Not mounted at all:** `~/.ssh`, `~/.config/tea`, `~/.config/pulse`, `~/.config/agent-pool`
  (the signing key) and `/run/user/<uid>` (the ssh and gpg agent sockets).
- **Main clone:** read-only, at its real path, because the worktree's `.git` file points into it
  and the worker's read-only git needs it.

Tests: a stub worker inside the jail can't read the signing key, can't reach the agent socket,
and can't write to `MAIN/.git`. Live check: each provider's auth works from inside the jail. This
removes §2.3's residual.

**Step 14. Re-enable agy resolve (decision 8).** agy gets resolve back only when **all** of these
hold:

- Step 13 is live for agy: it runs in the jail with no keys.
- The controller owns all commits and pushes, which is steps 6 and 10 of this plan.
- `--dangerously-skip-permissions` is passed only inside the jail.

The change:

- `job_providers` re-adds agy for resolve behind `AGENT_POOL_AGY_RESOLVE=1`. That flag is a
  SETUP FAULT unless the jail is active for agy, and the retired `AGY_AUTO_APPROVE` stays a fault.
- agy's tree is checkpointed and committed by the controller like any provider. Any commits it
  makes itself inside the jail are ignored, because `stage_tree` reads files, not HEAD, and the
  `worker_head` assertion makes them a `fail:`.

Tests:

- agy resolve is refused without the jail.
- With the jail, a stub agy that tries `git push`, reads `~/.ssh` and runs `git commit` achieves
  none of them, and its file edits are committed by the controller with
  `Agent-Provider: agy`.

**Optional step 15 (after live use). Gates on review jobs.** The controller runs the manifest's
gates at the PR head before spawning a reviewer, writes the results into the context file, and
posts `agent-pool/gates` on that head. Every head the pool has seen then carries the status, and
`pr-merge.sh` can require it universally (§7, open question 2).

---

## 7. Decisions (Oct 17), new open questions, and risks

### Decisions (Oct 17)

1. **The controller makes the commits (Craig).**
   - Workers only edit files. Worker git is `status`, `diff`, `log` and `show`. `git add` and
     `git commit` are dropped from the allowlist (§5.1).
   - The controller stages with `gate_git` (no worker-controlled config or hooks). It rejects
     protected paths, symlinks, gitlinks, mode changes and oversized blobs (§2.1-2.2).
   - Commits are signed with a controller-owned **ssh** key at
     `~/.config/agent-pool/signing/pool_ed25519`, which workers and gate sandboxes can't reach
     (§2.3).
   - Trailers `Agent-Provider`, `Agent-Model`, `Agent-Attempt`, `Agent-Job` and an optional
     `Co-authored-by` come from the claim record and adapter metadata only (§2.4).
   - The worker proposes a commit message, and the controller sanitizes it, with a
     controller-written fallback (§2.4).
   - `gitea-pr.py merge`, called by `pr-merge.sh`, verifies pool signatures, and Gitea shows them
     as Verified through a dedicated pool account (§4.5).
2. **Commit early and often (Craig).**
   - Signed checkpoints go to `refs/agent-pool/attempts/<attempt_id>` every 300s if the tree
     changed, at Claude's Edit and Write boundaries, and once more when the worker ends (§2.5).
   - A cutoff loses no work. The next attempt or provider resumes from the last checkpoint (§2.6).
   - **Push policy:** checkpoints stay local and are never pushed. One squashed, gated commit per
     job is pushed (§2.7).
   - A stale holder's checkpoints are never pushed and never become resume points after its
     deadline (§2.5, §2.7).
3. **Push anyway (Craig).**
   - Gates run at the candidate, and at the baseline `sha` for any gate that's red at the
     candidate.
   - "New failure" is defined per gate by `compare = exit | junit | lines` (§3.5).
   - No new failures means the commit is pushed. Pre-existing red is listed in the PR comment and
     makes the status `failure` (§4.5, §4.7).
4. **Timing.** `WORKER_TIMEOUT=1800`, `AGENT_POOL_GATE_BUDGET=1200`,
   `AGENT_POOL_DEADLINE_SECS=3300`, justified by checkpointing (§4.8).
5. **Infra requeue keeps the work.** The final commit stays on `refs/agent-pool/final/<id>`, and
   the next tick re-gates it without a provider run (§4.4).
6. **No registry tokens.** The warm step gets no credentials, and manifests can't add env (§1,
   §3.3).
7. **No gate needs `.git`.** The gate dir has none. `needs_git` is a reserved manifest key for
   later (§1, §3.1).
8. **agy stays review-only (Craig).** Resolve comes back through §6 step 14, once workers run in
   the bwrap jail with no keys (step 13) and the controller owns all commits and pushes.
9. **Commit status.** `agent-pool/gates` is `success` or `failure` on every pool-pushed commit.
   `pr-merge.sh` requires `success` from the pool's creator on pool-authored heads (§4.5).

### New open questions

1. **A Gitea account for the pool's identity.** The plan assumes a new `agent-pool` Gitea user
   that holds the signing key and the pool email, with no repo permissions, so pool commits show
   as Verified for a distinct identity. The alternative is putting the signing key on Craig's
   account, which would show pool commits as "Verified: Craig". Is a new account OK?
2. **Require `agent-pool/gates` on human heads too?** v1 requires it only when the head is a pool
   commit (§4.5 rule 3). Requiring it on every head means gates on review jobs (optional step 15)
   and would block automerge for any PR the pool hasn't gated. Is that wanted, and before or
   after live use?
3. **Worker jail timing.** Step 13 is planned as its own PR after this one. Until it lands, the
   signing key's protection from a same-uid worker rests on CLI tool scoping (§2.3). Is that
   residual acceptable for the gap, with resolve jobs still not scheduled unattended (§8)? The
   other option is to fold step 13 into this follow-up.
4. **Checkpoint backup.** Checkpoints are local-only under D2. Do you want an off-host mirror of
   `refs/agent-pool/*` (for example a nightly bundle), or is losing them with the host
   acceptable?

### Risks

- **Gates still run PR code.** The sandbox is what contains it, so a bwrap or kernel escape is
  the residual risk. A separate unix user for gates (D1's option (b)) is the next layer if you
  want one. It's not in this plan.
- **The signing key is a same-uid file until step 13.** Its protection is CLI tool scoping plus
  `SENSITIVE`. A separate signer uid, or the step 13 jail, is the next layer.
- **Warm runs human code with network.** That's `dotnet restore` MSBuild evaluation, and
  `npm`/`composer` with scripts disabled, from `sha`'s tree. When the PR changed a lockfile or
  MSBuild file, that tree is unmerged human code. It never sees a key, but could exfiltrate what
  the warm sandbox can see, which is that tree.
- **`exit`-mode gates can hide new failures behind a red gate.** "Red before and after" is
  treated as pre-existing. The status is still `failure`, so it never auto-merges, and the comment
  recommends `junit` or `lines`.
- **Gate integrity is not the same as test integrity.** `protect` stops the worker redefining
  the gate *command*. The junit "deleted passing test" rule catches removal. It doesn't catch a
  test weakened in place. That is still the reviewer's job: the next review pass sees the diff.
- **Timer checkpoints can capture half-written files.** They're resume points only. The gated
  commit is staged after the worker is dead.
- **Fence window.** A checkpoint's claim check and its update-ref aren't atomic. A holder
  superseded in that gap could write one more checkpoint to its own attempt ref, and to the
  pointer. The resume checks (§2.6) and the successor's re-gate bound the harm: that work is
  re-staged, re-gated and pushed only as the successor's own commit.
- **Cursor's `Read`/`Write` globs and Grok's rules have no hook.** Their scope is only as good as
  each CLI's matcher. The shim covers git argv, but not native file tools.
- **Local state is load-bearing.** Receipts, checkpoint refs, the cache and the fault files live
  on one host, consistent with D2. A second host would not see receipts, and would refuse to
  settle resolves the first host gated. That's safe but noisy.
- **Disk.** A full gate dir per run (with `node_modules`), baseline caches, checkpoint refs and a
  per-repo dependency cache. `end_job` removes gate dirs. The cache and refs need the `doctor.sh`
  pruning in step 12.

---

## 8. Recommendation: a follow-up PR after #2 merges

**Land this as its own PR on top of `master` once #2 has merged. Don't fold it into #2. Build
nothing until then.**

- **#2 is still moving.** Clyde is fixing round-4 findings (10511) on #2 right now, and they're in
  exactly the files this plan rewrites: `policy.py`'s `tokenize`, `sensitive` and `options_ok`,
  and `prod-common.sh`'s `publish`. Folding this in would make Clyde's in-flight fixes and this
  redesign conflict. It would also restart the review count on a PR that is converging (465 and
  214 offline tests, four rounds, one blocker left).
- **The two have different review shapes.** #2 is "is this controller correct". This change is
  "is this trust model right": a sandbox, a manifest format, a gate taxonomy, a signing key and a
  checkpoint protocol. It also needs live checks on cachyos and Gitea (§6 step 11) that #2
  doesn't, and those shouldn't block #2.
- **Merging #2 first is safe.** Nothing in #2 is live: `PROVIDER_ORDER` defaults to Claude, and
  there are no entrypoints and no systemd units. The D1 exposure only exists once resolve jobs run
  unattended. Until this follow-up lands, record in the plan doc (one line, which Clyde can add in
  round 4) that **resolve jobs are not to be scheduled unattended**.
- **#2's round-4 fixes aren't wasted.** The brace and path-normalisation fixes are reused by the
  shim's raw check and by the review policy. The only round-4 suggestion to skip is the narrow
  `2>&1` allowance, because step 10 deletes the reason for it.
- **Ordering inside the follow-up matters.** Steps 1 to 9 add controller commits, checkpoints,
  gates and the merge-loop check. Step 10 then removes worker gates, `git add` and `git commit`.
  That's easier to review as a short stack of commits on a fresh branch than as more commits on
  top of #2's four rounds. The worker jail (step 13) and agy resolve (step 14) follow as separate
  PRs.
