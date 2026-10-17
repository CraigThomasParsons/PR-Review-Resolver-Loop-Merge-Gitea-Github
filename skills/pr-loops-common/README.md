# pr-loops-common

Shared implementation for the `pr-review-loop`, `pr-resolve-loop`,
`pr-review-resolve-loop`, and `pr-merge-loop` skills. This folder is not a skill itself; it has
no `SKILL.md` on purpose.

- `pr-loop.sh review|resolve` one tick of the loop
- `pr-merge.sh` one mechanical, opt-in merge tick (no model worker)
- `prompts/review.txt`, `prompts/resolve.txt` the prompts pasted into each worker
- `prompts/review.generic.txt`, `prompts/resolve.generic.txt` provider-neutral prompts for the
  headless agent pool (`../../agent-pool/prod-common.sh`); no Claude-only skills, and staging is
  by named path only
- `marker.py` reads the hidden `pulse-review:v1` and `pulse-resolve:v1` markers off a PR. A
  resolve marker counts each finding as `fixed`, `noted` (non-blocking, left for the author) or
  `deferred` (blocking); only `deferred` sends a PR to `review:needs-human`
- `gitea-pr.py` the Gitea adapter (list, head, label, comment, comments, threads, diff, merge)
- `classify-pane.sh` classifies a worker pane (WORKING, BLOCKED, PARKED, DONE, IDLE, STALLED)
  from the pane text and an idle-streak state file. The loop depends on the four-argument form
  and the PARKED and STALLED states, which the tmux-pipeline skill's classifier does not provide.
- `tests/verify-resolve.sh` offline cases for the resolve verification gate; run it after any
  edit to `verify()` in `pr-loop.sh`
- `tests/verify-merge.sh` offline cases for merge candidate and safety gates
- `tests/verify-lease.sh` offline cases for the agent pool's leases, fence tokens, hold state,
  cooldowns and limit classification
- `tests/verify-providers.sh` offline end-to-end ticks of the agent pool against stub provider
  CLIs, a stub Gitea adapter and a local git remote

Operator setup: [`docs/agents/pr-loops-setup.md`](../../../docs/agents/pr-loops-setup.md).
