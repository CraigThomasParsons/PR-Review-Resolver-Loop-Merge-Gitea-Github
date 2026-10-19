#!/usr/bin/env bash
# night_shift_maintenance.sh: TheNightCrew maintenance entry point for this repository (#18).
#
# Usage (the NightCrew client): night_shift_maintenance.sh <project_dir> <task>
#
# Closed allowlist. `quality` runs the repository's offline verify suites from the project
# checkout; they write only temporary directories. Any other task exits 2.
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
    for suite in agent-pool/tests/verify-*.sh skills/pr-loops-common/tests/verify-*.sh tests/verify-*.sh \
        scripts/tools/tests/verify-*.sh; do
      [ -f "$suite" ] || continue
      if bash "$suite" >/dev/null 2>&1; then
        log "ok   ${suite}"
      else
        log "FAIL ${suite}"
        failed=1
      fi
    done
    exit "$failed"
    ;;
  *)
    log "ABORT — unknown maintenance task: ${TASK}"
    exit 2
    ;;
esac
