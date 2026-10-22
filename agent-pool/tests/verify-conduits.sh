#!/usr/bin/env bash
# Offline acceptance gate for the Conduit registry (#12): the unit and SQLite integration tests
# under agent-pool/tests/conduits, then agent-pool/tests/features/conduits.feature, both run by one
# selected interpreter, ${CONDUITS_PYTHON:-python3}, from this checkout's root.
#
# Behave is a development dependency pinned in agent-pool/tests/requirements-conduits.lock; the
# registry itself is stdlib only. A missing or broken interpreter, or one without Behave, fails the
# gate: the Gherkin is never skipped. Behave's exit status alone is not acceptance either: its
# JSON result must show at least one scenario with every scenario and step passed
# (agent-pool/tests/check-behave-result.py), so an empty, filtered, skipped, undefined or pending
# run fails. All state lives in temporary directories; nothing touches the network.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$ROOT"
PYTHON="${CONDUITS_PYTHON:-python3}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RESULT="$TMP/behave-result.json"

log() { printf '[verify-conduits] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "FAIL $*"; exit 1; }
run() { # logs the exact command, then runs it with the scripts directory importable
  log "run (cwd ${ROOT}): PYTHONPATH=agent-pool/scripts $*"
  PYTHONPATH=agent-pool/scripts "$@"
}

if ! command -v -- "$PYTHON" >/dev/null 2>&1; then
  die "interpreter not found: ${PYTHON} (set CONDUITS_PYTHON to a Python with the locked Behave installed)"
fi
if ! VERSION="$("$PYTHON" -c 'import sys; print(sys.version.split()[0])' 2>&1)"; then
  die "interpreter does not run: ${PYTHON}"
fi
log "interpreter ${PYTHON} (Python ${VERSION})"
if ! BEHAVE_VERSION="$("$PYTHON" -m behave --version 2>&1)"; then
  die "Behave is not installed for ${PYTHON}; install agent-pool/tests/requirements-conduits.lock (see its header)"
fi
log "behave: ${BEHAVE_VERSION}"

UNIT=0
run "$PYTHON" -m unittest discover -s agent-pool/tests/conduits -p 'test_*.py' -v || UNIT=$?
log "unittest exit ${UNIT}"

GHERKIN=0
run "$PYTHON" -m behave agent-pool/tests/features/conduits.feature --format json --outfile "$RESULT" || GHERKIN=$?
log "behave exit ${GHERKIN}"

CHECKED=0
run "$PYTHON" agent-pool/tests/check-behave-result.py "$RESULT" || CHECKED=$?
log "behave result check exit ${CHECKED}"

if [ "$UNIT" -ne 0 ] || [ "$GHERKIN" -ne 0 ] || [ "$CHECKED" -ne 0 ]; then
  die "unittest ${UNIT}, behave ${GHERKIN}, behave result ${CHECKED}"
fi
log "PASS unittest, behave and the behave result check"
