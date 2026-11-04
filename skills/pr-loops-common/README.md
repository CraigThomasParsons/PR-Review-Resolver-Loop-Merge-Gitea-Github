# pr-loops-common

Shared implementation for the `pr-review-loop`, `pr-resolve-loop`,
`pr-review-resolve-loop`, and `pr-merge-loop` skills. This folder is not a skill itself; it has
no `SKILL.md` on purpose.

- `pr-loop.sh review|resolve` one tick of the loop
- `pr-merge.sh` one mechanical, opt-in merge tick (no model worker)
- `pr-trigger.sh` the event entry point, installed as `~/.local/bin/pr-trigger`: validates
  `--repo --pr --sha [--event] [--label]` and queues the PR (exit 0/2/3)
- `pr-drain.sh` installed as `~/.local/bin/pr-drain`, run by `pr-trigger-drain.service`: takes
  each queued PR through label, review and resolve. See `docs/EVENT-TRIGGER.md`
- `prompts/review.txt`, `prompts/resolve.txt` the prompts pasted into each worker
- `prompts/review.generic.txt`, `prompts/resolve.generic.txt` provider-neutral prompts for the
  headless agent pool (`../../agent-pool/bin/prod-common.sh`); no Claude-only skills, staging is
  by named path only, and workers never push or comment (the pool controller publishes).
  Resolve workers must not run unattended until the controller-gates follow-up (branch
  docs/controller-gates-plan, docs/plans/controller-gates.md) lands.
- `prompts/review.agy.txt` the review prompt for Agy, which runs in plan mode with no commands;
  the controller (the agent pool, or `pr-loop.sh` on a Claude limit) gathers the diff and
  discussion into a context file for it and posts Agy's response as the review
- `provider-fallback.py` records a provider's usage limit with the reset time parsed from its
  message (six hours when it names none; `PR_LOOP_LIMIT_DEFAULT_SECS`) under
  `$PR_LOOP_STATE/provider-limits/`, and checks Agy's JSON result against the review marker.
  While a Claude limit stands, review ticks go straight to Agy and resolve ticks leave PRs at
  `review:findings`
- `marker.py` reads the hidden `pulse-review:v1` and `pulse-resolve:v1` markers off a PR. A
  resolve marker counts each finding as `fixed`, `noted` (non-blocking, left for the author) or
  `deferred` (blocking); only `deferred` sends a PR to `review:needs-human`
- `gitea-pr.py` the Gitea adapter (list, head, labels, state, label, comment, comments,
  threads, diff, merge)
- `classify-pane.sh` classifies a worker pane (WORKING, BLOCKED, RATE_LIMITED, EXITED, PARKED,
  DONE, IDLE, STALLED) from the pane text and an idle-streak state file. The loop depends on the
  four-argument form and the RATE_LIMITED, EXITED, PARKED and STALLED states, which the
  tmux-pipeline skill's classifier does not provide. RATE_LIMITED (HTTP 429, "hit your weekly
  limit", "usage limit", the "Stop and wait" menu) gets the Claude worker killed at the next poll
  and the review rerun under Agy
- `tests/verify-composer.sh` offline cases for the composer install step: which directories are
  installed, the `PR_LOOP_COMPOSER_*` knobs, and whole review ticks in which a failed install
  stops the PR without starting a worker, against a stub composer
- `tests/verify-resolve.sh` offline cases for the resolve verification gate; run it after any
  edit to `verify()` in `pr-loop.sh`
- `tests/verify-merge.sh` offline cases for merge candidate and safety gates
- `../../agent-pool/tests/verify-lease.sh` offline cases for the agent pool's write-once claim
  records and attempt fencing, hold state, cooldowns, limit classification, prompt rendering and
  worker permission policy
- `../../agent-pool/tests/verify-providers.sh` offline end-to-end ticks of the agent pool against
  stub provider CLIs, a stub Gitea adapter and a local git remote
- `tests/verify-trigger.sh` offline cases for `pr-trigger`, `pr-drain` and the `PR_LOOP_PR` /
  `PR_LOOP_LOCK_WAIT` knobs in `pr-loop.sh`
- `tests/verify-fallback.sh` offline cases for the usage-limit fallback: the RATE_LIMITED and
  EXITED pane classes, reset-time parsing, and whole review and resolve ticks against stub
  `claude`, `agy`, `tmux`, `git` and Gitea adapter

## Dependencies in the worker's worktree

`pr-loop.sh` gives each PR a fresh detached worktree, which has no `vendor/`, so a PHP repo's gate
(`composer test`, `vendor/bin/phpunit`, `pint`) cannot run there as checked out. After the
worktree is added and before any worker starts (Claude or the Agy fallback), the loop runs
`composer install --no-interaction --no-progress --working-dir=<dir>` once in every directory of
the worktree that holds a `composer.lock`. `vendor/`, `node_modules/` and `.git` are not searched,
since a lock there belongs to a dependency. A worktree with no `composer.lock` skips the step
silently. Composer's output (last 20 lines per directory) goes to the loop log.

| Variable | Default | Effect |
| --- | --- | --- |
| `PR_LOOP_COMPOSER_INSTALL` | `1` | `0` skips the step |
| `PR_LOOP_COMPOSER_DIRS` | unset | Space-separated directories, relative to the worktree, to install in instead of discovering them. Each must hold a `composer.lock`. |
| `PR_LOOP_COMPOSER_BIN` | `composer` | The binary to run (the tests use a stub) |

The PR stops when an install exits non-zero, when a lock exists but the composer binary is not on
PATH, or when a directory named in `PR_LOOP_COMPOSER_DIRS` has no lock. Installing stops at the
first failure. The loop then logs the reason, moves the PR from its claim label to
`review:needs-human` with a comment giving the reason (for example
`composer install failed in apps/game (exit 2)`) and an excerpt of composer's output, and removes
the worktree. No worker is started, and the PR's slot goes to the next one in the queue. Dry runs
never create a worktree, so they never install.

TODO: resolve has no fallback provider. Agy has no tool deny list, so the agent pool never lets it
resolve and neither does this loop; a resolve that hits a Claude limit is killed and handed back
to `review:findings` until the reset. A resolve fallback needs a provider with a deny list (the
agent pool's grok or cursor adapters) and the pool's controller-side push gates.

Production runs a copy of this folder deployed by the repo's top-level `install.sh`;
`.deployed-from` in the deployed copy names the commit.

Operator setup: [`docs/agents/pr-loops-setup.md`](../../../docs/agents/pr-loops-setup.md).
