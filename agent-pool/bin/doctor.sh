#!/usr/bin/env bash
# doctor.sh: one tick of the agent pool's doctor (systemd agent-pool-doctor.service).
#
# Requeues stale claims and claims whose tick died, and moves queued jobs no enabled, installed
# provider can take to agent:needs-human; scripts/doctor.py has the whole contract. It never
# invokes an LLM CLI, never deletes anything, and runs one instance at a time.
#
# Usage: doctor.sh [--dry-run] [--report FILE] [--repo OWNER/NAME ...]   (DOCTOR_DRY_RUN=1 too)
# Exit codes: 0 done (or another doctor tick still running); 1 an action failed; 2 unusable config.
set -euo pipefail

# Belt and braces with the unit's own PATH: a non-interactive shell's PATH has bitten this box.
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
here="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
state="${AGENT_POOL_STATE:-$HOME/.local/state/agent-pool}"
mkdir -p "$state"
exec 9>"$state/doctor.lock"
if ! flock -n 9; then
  printf '%s [doctor] previous doctor tick still running; exiting\n' "$(date -Is)" >&2
  exit 0
fi
exec python3 "$here/../scripts/doctor.py" "$@"
