# AGENTS.md

Label-driven PR review/resolve/merge loop for Gitea, plus (in progress) a pull-based
multi-provider worker pool. See `README.md` for what's here, `docs/plans/` for design docs.

## Branching

PRs target `master`. Never commit directly to `master`. Branch prefixes: `feature/`, `fix/`,
`docs/`, `chore/`.

## Style

- **Bash** (`skills/pr-loops-common/*.sh`, `agent-pool/bin/*.sh` once it exists): `set -euo
  pipefail` at the top of every script, matching `pr-loop.sh`/`pr-merge.sh`'s existing style.
  Quote every variable expansion. Prefer `flock` over ad hoc lock files for mutual exclusion.
- **Python** (`skills/pr-loops-common/*.py`, `agent-pool/scripts/*.py` once it exists): match
  `~/.codex/skills/tmux-multi-pipeline/lease.py`'s style — type hints on function signatures,
  atomic writes via `tempfile.mkstemp` + `os.replace` + fsync (never a bare `open(..., 'w')`
  for anything another process might read concurrently), no bare `except:`.
- No secrets committed, ever: `.env`, tokens, private keys. Run before every commit:
  ```bash
  git diff --cached --name-only | grep -Ei '(\.env|gitea_token|id_rsa|\.pem$)' || echo "clean"
  ```

## Gate

There is no single repo-wide test command yet — this repo is young and most of it (the
`agent-pool/` worker pool) doesn't exist on disk yet. Each slice's issue names the specific
test script(s) it must pass (for example `agent-pool/tests/verify-claim-record.sh`). Run
exactly those; report plainly if a named script doesn't exist yet or can't run, rather than
skipping silently or inventing a substitute gate.

## Hard rules

- Never merge a PR. That's `pr-merge-loop`'s job (a separate, deliberately mechanical tick),
  or a human, never the worker that opened the PR.
- Never apply `night-crew: approved` or `ready-for-agent` to an issue. Only Craig authorizes
  unattended work.
- `agent-pool/doctor.sh`, once it exists, must never invoke an LLM CLI (`claude`, `codex`, or
  any other provider binary) — it is the one thing in this repo that must not itself be
  rate-limitable. See `docs/plans/agent-pool-worker-pool.md`.
