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
- `marker.py` reads the hidden `pulse-review:v1` and `pulse-resolve:v1` markers off a PR. A
  resolve marker counts each finding as `fixed`, `noted` (non-blocking, left for the author) or
  `deferred` (blocking); only `deferred` sends a PR to `review:needs-human`
- `gitea-pr.py` the Gitea adapter (list, head, labels, label, comment, comments,
  threads, diff, merge)
- `classify-pane.sh` classifies a worker pane (WORKING, BLOCKED, PARKED, DONE, IDLE, STALLED)
  from the pane text and an idle-streak state file. The loop depends on the four-argument form
  and the PARKED and STALLED states, which the tmux-pipeline skill's classifier does not provide.
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

Production runs a copy of this folder deployed by the repo's top-level `install.sh`;
`.deployed-from` in the deployed copy names the commit.

Operator setup: [`docs/agents/pr-loops-setup.md`](../../../docs/agents/pr-loops-setup.md).
