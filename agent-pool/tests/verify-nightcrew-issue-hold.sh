#!/usr/bin/env bash
# Offline unit cases for nightcrew-issue-hold.py's own logic: held_by() and its
# fail-closed behavior on a read error. No network -- urllib.request.urlopen is
# monkeypatched.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/nightcrew-issue-hold.py"

pass=0; fail=0
check() { # name expected-output python-fixture
  local got
  got="$(GITEA_TOKEN=x python3 - "$SCRIPT" <<PY
import importlib.util, io, json, sys, types
spec = importlib.util.spec_from_file_location("hold", sys.argv[1])
hold = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hold)

$3

sys.argv = ["nightcrew-issue-hold.py", "--repo", "owner/repo", "--bot", "night-crew-bot"]
hold.main()
PY
)"
  if [ "$got" = "$2" ]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n         wanted %s\n         got    %s\n' "$1" "$2" "$got"; fi
}

check "no assignees anywhere -> clear" "clear" '
hold.open_issues = lambda repo: [{"assignees": []}, {"assignees": None}]
'

check "a different assignee -> clear" "clear" '
hold.open_issues = lambda repo: [{"assignees": [{"login": "someone-else"}]}]
'

check "the bot is assigned to one open issue -> busy" "busy" '
hold.open_issues = lambda repo: [{"assignees": [{"login": "someone-else"}]},
                                  {"assignees": [{"login": "night-crew-bot"}]}]
'

check "no open issues at all -> clear" "clear" '
hold.open_issues = lambda repo: []
'

check "a read failure resolves to busy, not clear" "busy" '
def boom(repo):
    raise OSError("network unreachable")
hold.open_issues = boom
'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
