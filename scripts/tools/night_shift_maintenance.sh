#!/usr/bin/env bash
# night_shift_maintenance.sh: TheNightCrew maintenance entry point for this repository (#18).
#
# Usage (the NightCrew client): night_shift_maintenance.sh <project_dir> <task>
#
# Closed allowlist. `quality` runs the repository's offline verify suites from the project
# checkout; they write only temporary directories. It fails if any suite fails or none exists.
# night_shift.sh runs it on its worktree as the gate before committing the worker's edits. Any
# other task exits 2.
set -euo pipefail

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[night_shift_maintenance] $(ts) $*"; }

if [ "$#" -ne 2 ]; then
  log "ABORT — Usage: night_shift_maintenance.sh <project_dir> <task>"
  exit 2
fi
PROJECT_DIR="$1"
TASK="$2"
if ! git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log "ABORT — not a git checkout: ${PROJECT_DIR}"
  exit 2
fi

case "$TASK" in
  quality)
    cd "$PROJECT_DIR"
    failed=0
    ran=0
    output="$(mktemp)"
    trap 'rm -f "$output"' EXIT
    for suite in agent-pool/tests/verify-*.sh skills/pr-loops-common/tests/verify-*.sh tests/verify-*.sh \
        scripts/tools/tests/verify-*.sh; do
      [ -f "$suite" ] || continue
      ran=$((ran + 1))
      # A minimal environment: operator variables (AGENT_POOL_*, PROVIDER_ORDER ...) inherited
      # from the caller change what the suites exercise and fail them with no real defect.
      if env -i HOME="$HOME" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" LANG="${LANG:-C.UTF-8}" \
          bash "$suite" > "$output" 2>&1; then
        log "ok   ${suite}"
      else
        log "FAIL ${suite}"
        tail -n 20 "$output"
        failed=1
      fi
    done
    # The night-shift launcher commits only on a passing run, so finding nothing to run fails.
    if [ "$ran" -eq 0 ]; then
      log "FAIL no offline verify suite found"
      failed=1
    fi
    exit "$failed"
    ;;
  *)
    log "ABORT — unknown maintenance task: ${TASK}"
    exit 2
    ;;
esac
