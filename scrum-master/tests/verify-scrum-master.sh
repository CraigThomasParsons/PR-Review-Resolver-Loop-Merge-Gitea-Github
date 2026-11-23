#!/usr/bin/env bash
# Gate for scrum-master/: the offline unit tests (fake Gitea, fake Slack, a throwaway
# NightCrew-shaped SQLite file), a byte-compile, and a check that the units parse.
# Nothing here reaches the real Gitea, Slack or NightCrew, and nothing is installed.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
python3 -m py_compile scrum-master/scrum_master.py
python3 -m unittest discover -s scrum-master/tests -p 'test_*.py' -v
if command -v systemd-analyze > /dev/null 2>&1; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  sed "s#@HSM_ROOT@#$ROOT#" systemd/hermes-scrum-master.service > "$tmp/hermes-scrum-master.service"
  cp systemd/hermes-scrum-master.timer "$tmp/"
  if out="$(SYSTEMD_UNIT_PATH="$tmp:" systemd-analyze --user verify --man=no \
      "$tmp/hermes-scrum-master.service" "$tmp/hermes-scrum-master.timer" 2>&1)"; then
    echo "ok    systemd-analyze verify accepts the units"
  elif grep -qiE 'bus|connect|user manager' <<< "$out"; then
    echo "skip  systemd-analyze could not reach a user manager here: $(head -1 <<< "$out")"
  else
    printf '%s\n' "$out" >&2
    echo "FAIL  systemd-analyze verify" >&2
    exit 1
  fi
fi
echo "verify-scrum-master: all passed"
