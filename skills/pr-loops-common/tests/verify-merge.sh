#!/usr/bin/env bash
# Offline behavior cases for the mechanical merge tick.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state"
SHA=1111111111111111111111111111111111111111

write_adapter() { # labels-json mergeable(true|false)
  local mergeable="False"
  [ "$2" = "true" ] && mergeable="True"
  cat > "$TMP/adapter.py" <<PY
import json, sys
args = sys.argv[1:]
if args[0] == "list":
    print(json.dumps([{"number": 7, "title": "feature", "draft": False,
      "head_sha": "$SHA", "head_ref": "feature/test", "base_ref": "develop",
      "author": "human", "is_bot": False, "labels": $1, "url": ""}]))
elif args[0] == "merge":
    print("ok") if $mergeable else sys.exit("not mergeable")
else:
    print("ok")
PY
}

write_marker() { # head
  cat > "$TMP/marker.py" <<PY
print("$1 0")
PY
}

run_tick() {
  DRY_RUN="${DRY_RUN_CASE:-0}" PR_LOOP_STATE="$TMP/state" \
    PR_MERGE_ADAPTER="$TMP/adapter.py" PR_MERGE_MARKER="$TMP/marker.py" \
    PR_LOOP_REPO=ElasticGun/TheNightCrew bash "$ROOT/pr-merge.sh" 2>&1
}

pass=0; fail=0
check() { # name expected
  local got
  got="$(run_tick)"
  if [[ "$got" == *"$2"* ]]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n         wanted *%s*\n         got %s\n' "$1" "$2" "$got"; fi
}

echo "merge tick gates"
write_marker "$SHA"
write_adapter '["review:clean", "review:automerge", "review:needs-human"]' true
check "needs-human wins" "no eligible open PR"

write_adapter '["review:clean"]' true
check "missing automerge skips" "no eligible open PR"

write_adapter '["review:clean", "review:automerge"]' true
write_marker 2222222222222222222222222222222222222222
check "head-moved marker fails closed" "FAILED: clean marker head"

write_marker "$SHA"
write_adapter '["review:resolved", "review:automerge"]' false
check "mergeable false fails closed" "FAILED: not mergeable"

write_adapter '["review:clean", "review:automerge"]' true
DRY_RUN_CASE=1 check "dry run prints would-merge without mutation" "would claim and merge head"
unset DRY_RUN_CASE

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
