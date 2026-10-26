#!/usr/bin/env bash
# Offline behavior cases for the mechanical merge tick.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state"
SHA=1111111111111111111111111111111111111111
OLD=3333333333333333333333333333333333333333

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
    if args[0] == "label":
        with open("$TMP/label-calls.log", "a") as log:
            log.write(" ".join(args) + "\n")
    print("ok")
PY
}

write_marker() { # head
  cat > "$TMP/marker.py" <<PY
print("$1 0")
PY
}

write_marker_split() { # resolve-line latest-line (each may be empty for "no marker")
  cat > "$TMP/marker.py" <<PY
import sys
if sys.argv[1] == "resolve":
    line = "$1"
else:
    line = "$2"
if line:
    print(line)
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

echo "agent-pool-core interop"
write_marker_split "" "$SHA 0"
write_adapter '["agent:done", "review:automerge"]' true
check "agent:done + clean marker merges" "merged head"

write_marker_split "$SHA $OLD 1 0 0" "$OLD 1"
write_adapter '["agent:done", "review:automerge"]' true
check "agent:done + resolved marker (deferred=0) merges" "merged head"

write_marker_split "$SHA $OLD 1 0 0" "$SHA 2"
write_adapter '["agent:done", "review:automerge"]' true
check "agent:done + resolve answering an older review skips" "not yet eligible"

write_marker_split "$SHA $OLD 1 0 0" ""
write_adapter '["agent:done", "review:automerge"]' true
check "agent:done + resolve marker with no review marker skips" "not yet eligible"

write_marker_split "$SHA $OLD 0 2 0" "$OLD 2"
write_adapter '["agent:done", "review:automerge"]' true
check "agent:done + resolved marker with deferred findings skips" "not yet eligible"

write_marker_split "" "2222222222222222222222222222222222222222 0"
write_adapter '["agent:done", "review:automerge"]' true
check "agent:done + stale clean marker skips" "not yet eligible"

write_marker "$SHA"
write_adapter '["agent:claimed", "review:automerge"]' true
check "agent:claimed blocks" "no eligible open PR"

write_adapter '["agent:needs-human", "review:automerge"]' true
check "agent:needs-human blocks" "no eligible open PR"

write_adapter '["agent:ready", "review:clean", "review:automerge"]' true
check "agent:ready blocks even with review:clean" "no eligible open PR"

echo "#31: ability requirement labels"
expect() { # name got wanted-substring
  if [[ "$2" == *"$3"* ]]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n         wanted *%s*\n         got %s\n' "$1" "$3" "$2"; fi
}
ABILITY_LABELS=(agent:plan agent:review agent:prototype agent:test-author agent:resolve agent:promote)
write_marker "$SHA"
for l in "${ABILITY_LABELS[@]}"; do
  write_adapter "[\"$l\", \"agent:ready\", \"review:clean\", \"review:automerge\"]" true
  check "#31: $l beside agent:ready blocks" "no eligible open PR"
done
write_adapter '["agent:resolve", "agent:claimed", "review:clean", "review:automerge"]' true
check "#31: an ability label beside agent:claimed blocks" "no eligible open PR"
write_marker_split "" "$SHA 0"
write_adapter '["agent:done", "agent:resolve", "agent:test-author", "review:automerge"]' true
: > "$TMP/label-calls.log"
check "#31: a leftover ability label beside agent:done does not block the merge" "merged head"
merged_call="$(grep -- '--add review:merged' "$TMP/label-calls.log")"
claim_call="$(grep -- '--add review:merging' "$TMP/label-calls.log")"
for l in "${ABILITY_LABELS[@]}"; do
  expect "#31: the claim strips $l" "$claim_call" "$l"
  expect "#31: the merged relabel strips $l" "$merged_call" "$l"
done
write_adapter '["agent:done", "agent:prototype", "review:automerge"]' false
: > "$TMP/label-calls.log"
check "#31: a failed merge with a leftover ability label still fails closed" "FAILED: not mergeable"
expect "#31: the failure relabel strips the ability labels too" \
  "$(grep -- '--add review:needs-human' "$TMP/label-calls.log")" "agent:prototype"

echo "#31: one label vocabulary across gitea-labels.py, pr-merge.sh and capabilities.py"
POOL_SCRIPTS="$ROOT/../../agent-pool/scripts"
vocab="$(python3 - "$ROOT/gitea-labels.py" "$POOL_SCRIPTS" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gitea_labels", sys.argv[1])
labels = importlib.util.module_from_spec(spec); spec.loader.exec_module(labels)
sys.path.insert(0, sys.argv[2])
import capabilities
want = set(capabilities.ABILITY_LABELS) | {"agent:promote"}
print("missing:" + ",".join(sorted(want - set(labels.LABELS))))
PY
)"
expect "#31: gitea-labels.py LABELS carries every ability label and agent:promote" "[$vocab]" "[missing:]"
for l in "${ABILITY_LABELS[@]}"; do
  expect "#31: pr-merge.sh knows $l" "$(cat "$ROOT/pr-merge.sh")" "$l"
done

echo "#31: capability acceptance (agent-pool/scripts/capabilities.py)"
capq() { AGENT_POOL_STATE="$TMP/capstate" env -u AGENT_POOL_ROSTER python3 "$POOL_SCRIPTS/capabilities.py" "$@"; }
expect "#31: match --order claude --requires resolve returns claude" "$(capq match --order claude --requires resolve)" "claude"
expect "#31: match --order agy --requires resolve returns nothing" "[$(capq match --order agy --requires resolve)]" "[]"
cq_json="$(capq check-queue --order agy --requires resolve --roster agy,claude)"
expect "#31 roster: check-queue --order agy --roster agy,claude reports resolve satisfiable" "$cq_json" '"satisfiable": true'
expect "#31 roster: and leaves it to claude's tick rather than needs-human" "$cq_json" '"verdict": "elsewhere"'
expect "#31 roster: with roster agy alone the same job is unsatisfiable" \
  "$(capq check-queue --order agy --requires resolve --roster agy)" '"verdict": "unsatisfiable"'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
