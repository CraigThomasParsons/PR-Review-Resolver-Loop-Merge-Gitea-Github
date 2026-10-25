# pr-loop-skills

A label-driven review, resolve, and merge loop for Gitea pull requests, plus
the Claude Code skills that drive it. GitHub support is not implemented —
the adapter is Gitea-only. Originally deployed loose under `~/.claude/skills/`,
never version controlled; this is that same content, given a real home.

## Plans
I want to set something up that automatically loops between reviewing and review resolving.

Once a person or bot is satisfied it gets labeled Auto-merge and if the person deems this to be worthy merges it. If there are merge issues, then deal with them and then merge unless the CI quality gates don't let it pass.

This is recommended for develop only and should never be hooked up to production.

An alternate form of this I would like to enable are long living feature branches. This goes against my ideals, no branch except main or develop should be long lived. However for A.I. long lived isn't very long. This is also for the purposes of Auto merging.

## What's here

- `skills/pr-loops-common/` — the engine. `pr-loop.sh` (list, filter, spawn one
  tmux worker per PR, wait, verify, relabel) for review and resolve,
  `pr-merge.sh` for the separate merge tick, `gitea-pr.py` (the Gitea
  adapter), `marker.py` (hidden-marker parsing), worker prompts.
- `skills/pr-review-loop/`, `skills/pr-resolve-loop/`,
  `skills/pr-review-resolve-loop/` — thin wrappers that each run `pr-loop.sh`
  in a specific mode.
- `skills/pr-review-resolver/` — the skill a resolve worker actually runs:
  address review comments or conflicts, land the fix on the PR's branch, never
  merge.
- `agent-pool/`: the pull-based, multi-provider worker pool (in progress): the
  controller tick `bin/prod-common.sh`; one thin entrypoint per provider,
  `bin/prod-{claude,cursor,grok,agy,codex}.sh`, ticking each repo with the abilities
  `~/.config/agent-pool/repos.toml` grants it (see `config/repos.example.toml`; a repo or
  ability that is not listed means review only, and agy never resolves); the non-LLM
  `bin/doctor.sh`, which requeues stalled claims and dead workers and sends jobs no enabled
  provider can take to `agent:needs-human`; `bin/install-systemd-units.sh`, which copies
  `systemd/agent-pool-*` into the user unit dir without enabling anything;
  `scripts/agent-labels.py`, which creates the `agent:*` labels on one repo; helper scripts
  and offline tests. Design in `docs/plans/agent-pool-worker-pool.md`. Workers never commit: the
  controller makes one SSH-signed commit per resolve run with `Agent-Pool-*` trailers, and resolve
  needs a controller-only signing key (setup and rotation: `docs/agent-pool-commit-signing.md`). `scripts/conduit_registry.py`
  and `scripts/conduit-registry.py` are the Conduit configuration registry (Slice 1: a versioned,
  configuration-only SQLite schema, the Charlie and Chase examples and a pure deny-by-default
  matcher, wired into nothing yet); see `docs/plans/conduit-registry.md`.
- `scripts/tools/`: the entry points TheNightCrew's client requires for every repository it
  serves. `night_shift.sh <project_dir> <issue> [agent]` is the issue executor, Cursor only:
  the launcher is the controller, so it prepares the worktree, runs `cursor-agent` under a
  generated edit-only `.cursor/cli.json` (no `git add`, `git commit` or `git push`), runs the
  offline suites on the edits, commits them itself with `Agent-Pool-Agent`/`Agent-Pool-Provider`
  trailers, then pushes, opens an unmerged PR and writes the task receipt. No diff or a failing
  suite commits nothing, exits 1 and is recorded in `logs/runs/issue-<n>-state.json`.
  The worker never commits or publishes. `night_shift_maintenance.sh <project_dir> quality` runs the
  offline verify suites (closed allowlist). `night_shift_gitea.py` makes the launcher's
  Gitea calls. See #18.
- `skills/pr-merge-loop/` — a **third, deliberately separate, mechanical**
  tick. No model worker at all: it merges only PRs an operator has explicitly
  labelled `review:automerge`, that also carry `review:clean`,
  `review:resolved` or agent-pool-core's `agent:done`, after re-verifying the marker, head, mergeability, and
  base branch immediately before calling `tea pr merge`. Review and resolve
  workers are denied `tea pr merge` and every merge-adjacent command outright
  — merging only ever happens through this one path. Allowlisted per-repo
  (`PR_MERGE_ALLOW_REPOS`, currently only `ElasticGun/TheNightCrew`) and
  requires explicit per-session authorization before a real (non-dry) run;
  see `skills/pr-loops-common/docs/HANDOFF-pr-automerge.md` for why it's
  structured this way.

See `skills/pr-loops-common/docs/pr-loops-setup.md` for the full operator
setup and `skills/pr-review-resolver/SKILL.md` for the resolver's own rules.

## Installing

Production (`~/.claude/skills/*` on the review host) is a **copy** of a
committed revision, not a symlink to this checkout. Deploy it with:

```sh
./install.sh --list       # dry run, including drift in the live copy
./install.sh              # deploy from a clean master checkout
./install.sh --rollback   # put the previous copy back
```

`install.sh` copies every `skills/<name>` from `git archive` (tracked files
only), stamps `.deployed-from`, installs `~/.local/bin/pr-trigger` and
`~/.local/bin/pr-drain`, installs and enables the `pr-trigger-drain` systemd
user units, and swaps each copy in atomically while holding the loop's locks.
It refuses a dirty tree, a non-master HEAD, or a live copy that was edited by
hand, unless told otherwise. See its header and
`skills/pr-loops-common/docs/EVENT-TRIGGER.md`.

For development only, `install_skills_and_actions.sh` symlinks the skills
instead, so edits here take effect immediately:

```sh
./install_skills_and_actions.sh --list        # dry run
./install_skills_and_actions.sh --target DIR  # e.g. a scratch skills directory
```

It never overwrites an existing plain directory or a differently-targeted
symlink without `--force` — see the script's own header comment for why
`~/.codex/skills/pr-review-resolver` specifically should not be a default
target. It is a separately maintained variant adapted for AMPB's
slice-pipeline, not an older copy of this one.

## Event trigger

Besides the hourly timer, a Gitea Actions job (template owned by
TheGiteaCodeFactory, `runs-on: factory-host`) calls
`~/.local/bin/pr-trigger --repo OWNER/NAME --pr N --sha HEAD [--event E] [--label L]`
on `pull_request_target`. It queues the PR and returns at once; a systemd path
unit runs `pr-drain`, which takes that one PR through label, review and resolve
under the same locks and markers as the timer. Contract, queue semantics,
Gitea checks and troubleshooting: `skills/pr-loops-common/docs/EVENT-TRIGGER.md`.

## Tests

```sh
skills/pr-loops-common/tests/verify-resolve.sh
skills/pr-loops-common/tests/verify-merge.sh
skills/pr-loops-common/tests/verify-trigger.sh
tests/verify-install.sh
agent-pool/tests/verify-lease.sh
agent-pool/tests/verify-providers.sh
agent-pool/tests/verify-nightcrew-issue-hold.sh
agent-pool/tests/verify-doctor.sh
agent-pool/tests/verify-systemd-units.sh
agent-pool/tests/verify-agent-labels.sh
agent-pool/tests/verify-conduits.sh
scripts/tools/tests/verify-night-shift.sh
```

`verify-conduits.sh` also needs Behave: it runs under `${CONDUITS_PYTHON:-python3}` and fails
when that interpreter lacks it. Install `agent-pool/tests/requirements-conduits.lock` into a
dedicated environment (see the lockfile header).

All offline: stubbed adapter and CLIs, temporary home, no systemctl. The labels test talks to
a fake Gitea on 127.0.0.1 only. `verify-night-shift.sh` uses a stub `cursor-agent` and a loopback fake Gitea
(`scripts/tools/tests/fake-gitea.py`).

## Not version controlled before this

The content here is the real, currently-running engine — not the older
GitHub/`gh`-oriented ancestor documented in scattered, untracked copies
elsewhere on this machine (different tracker, different paths, same original
idea). This repo starts from the version that is actually deployed and
observed working.
