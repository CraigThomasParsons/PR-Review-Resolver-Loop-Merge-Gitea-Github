#!/usr/bin/env bash
# Offline unit cases for the agent pool's lease, cooldown and classification helpers.
# A pinned clock (AGENT_POOL_NOW) steps across TTLs and cooldowns; nothing sleeps, nothing
# touches the network, and all state lives in a temp directory.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="$ROOT/agent-pool/scripts"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export AGENT_POOL_STATE="$TMP/state"
R=owner/repo

lease() { python3 "$SCRIPTS/lease.py" "$@"; }
cooldown() { python3 "$SCRIPTS/cooldown.py" "$@"; }
at() { local t="$1"; shift; AGENT_POOL_NOW="$t" "$@"; }

pass=0; fail=0
expect() { # name got wanted-substring
  if [[ "$2" == *"$3"* ]]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n         wanted *%s*\n         got %s\n' "$1" "$3" "$2"; fi
}
expect_rc() { # name got-rc wanted-rc
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n         wanted exit %s, got %s\n' "$1" "$3" "$2"; fi
}

echo "leases and fence tokens"
f1="$(at 1000 lease claim --repo $R --pr 7 --mode review --worker w1 --provider claude --ttl 100)"
expect "first claim gets fence 1" "$f1" "1"
at 1050 lease claim --repo $R --pr 7 --mode review --worker w2 --ttl 100 2>/dev/null
expect_rc "a live lease cannot be claimed" "$?" 3
at 1050 lease renew --repo $R --pr 7 --worker w1 --fence 1 --ttl 100
expect_rc "the holder renews (heartbeat)" "$?" 0
at 1140 lease check --repo $R --pr 7 --worker w1 --fence 1
expect_rc "renewal moved expiry past the original TTL" "$?" 0
at 1150 lease check --repo $R --pr 7 --worker w1 --fence 1 2>/dev/null
expect_rc "exactly at expires_at the lease is no longer held" "$?" 4
f2="$(at 1151 lease claim --repo $R --pr 7 --mode review --worker w2 --ttl 100)"
expect "an expired lease is reclaimable, with a higher fence" "$f2" "2"
at 1152 lease renew --repo $R --pr 7 --worker w1 --fence 1 2>/dev/null
expect_rc "the superseded holder cannot renew" "$?" 4

out="$(at 1152 lease guard --repo $R --pr 7 --worker w1 --fence 1 -- touch "$TMP/stale-write" 2>&1)"; rc=$?
expect_rc "a stale fence token blocks the write" "$rc" 4
expect "the blocked write is reported" "$out" "fence 1 is stale; current fence is 2"
[ -e "$TMP/stale-write" ] && got=ran || got=not-run
expect "the blocked command never ran" "$got" "not-run"
at 1152 lease guard --repo $R --pr 7 --worker w2 --fence 2 -- touch "$TMP/fresh-write"
[ -e "$TMP/fresh-write" ] && got=ran || got=not-run
expect "the current holder's write runs" "$got" "ran"
at 1152 lease guard --repo $R --pr 7 --worker w1 --fence 2 -- true 2>/dev/null
expect_rc "the right fence under the wrong worker is refused" "$?" 4

at 1300 lease claim --repo $R --pr 9 --mode review --worker same --ttl 100 >/dev/null
at 1500 lease claim --repo $R --pr 9 --mode review --worker same --ttl 100 >/dev/null
at 1501 lease guard --repo $R --pr 9 --worker same --fence 1 -- touch "$TMP/restart-write" 2>/dev/null
expect_rc "a restarted worker with the same id still cannot write on its old fence" "$?" 4
[ -e "$TMP/restart-write" ] && got=ran || got=not-run
expect "only the fence tells the two runs apart, and it held" "$got" "not-run"

at 1160 lease release --repo $R --pr 7 --worker w2 --fence 2 --outcome ok
at 1161 lease guard --repo $R --pr 7 --worker w2 --fence 2 -- true 2>/dev/null
expect_rc "a released lease authorises no more writes" "$?" 4
f3="$(at 1161 lease claim --repo $R --pr 7 --mode resolve --worker w3 --ttl 100)"
expect "a released lease is claimable and the fence keeps rising" "$f3" "3"

echo
echo "hold state (GiteaFence::issueHeldByHuman without the permanent hold)"
H=(--hold-labels "review:in-progress,status: in-progress" --bot pool-bot)
at 1170 lease hold --repo $R --pr 7 --labels '["review:in-progress"]' "${H[@]}" > "$TMP/h"
expect "a live bot lease is a bot hold" "$(cat "$TMP/h")" "live"
at 2000 lease hold --repo $R --pr 7 --labels '["review:in-progress"]' "${H[@]}" > "$TMP/h"
expect "in-progress after the pool's lease expired is a dead hold, reclaimable" "$(cat "$TMP/h")" "expired"
at 2000 lease hold --repo $R --pr 7 --labels '["review:requested"]' --assignees '["craig"]' "${H[@]}" > "$TMP/h"
expect "a human assignee is a human hold" "$(cat "$TMP/h")" "human"
at 2000 lease hold --repo $R --pr 7 --labels '["review:requested"]' --assignees '["pool-bot"]' "${H[@]}" > "$TMP/h"
expect "the bot's own assignment is not a human hold" "$(cat "$TMP/h")" "free"
at 2000 lease hold --repo $R --pr 8 --labels '["status: in-progress"]' --grace 600 "${H[@]}" > "$TMP/h"
expect "status: in-progress with no pool lease starts a grace period" "$(cat "$TMP/h")" "orphan-pending"
at 2599 lease hold --repo $R --pr 8 --labels '["status: in-progress"]' --grace 600 "${H[@]}" > "$TMP/h"
expect "inside the grace period it is still pending, not human" "$(cat "$TMP/h")" "orphan-pending"
at 2600 lease hold --repo $R --pr 8 --labels '["status: in-progress"]' --grace 600 "${H[@]}" > "$TMP/h"
expect "after the grace period the orphan hold has expired" "$(cat "$TMP/h")" "orphan-expired"
at 2601 lease hold --repo $R --pr 8 --labels '["review:requested"]' --grace 600 "${H[@]}" > /dev/null
at 2602 lease hold --repo $R --pr 8 --labels '["status: in-progress"]' --grace 600 "${H[@]}" > "$TMP/h"
expect "a hold that went away and came back starts its grace again" "$(cat "$TMP/h")" "orphan-pending"
f9="$(at 2603 lease claim --repo $R --pr 8 --mode review --worker w1)"
expect "the first pool claim on an orphan-tracked PR is fence 1" "$f9" "1"

echo
echo "cooldowns"
export AGENT_POOL_COOLDOWN_BASE=3600 AGENT_POOL_COOLDOWN_CAP=86400
expect "first limit cools down for 1h" "$(at 10000 cooldown record --provider claude --reason x)" $'\t3600'
expect "second limit doubles to 2h" "$(at 10001 cooldown record --provider claude --reason x)" $'\t7200'
for t in 10002 10003 10004 10005; do at $t cooldown record --provider claude --reason x >/dev/null; done
expect "the sixth limit is capped at 24h" "$(at 10006 cooldown record --provider claude --reason x)" $'\t86400'
at 10007 cooldown active --provider claude >/dev/null
expect_rc "the provider is cooling" "$?" 0
expect "eligible skips a cooling provider and keeps order" "$(at 10007 cooldown eligible --order claude,cursor,grok | tr '\n' ' ')" "cursor grok "
at 10007 cooldown eligible --order claude >/dev/null
expect_rc "no eligible provider exits 1" "$?" 1
expect "the cooldown expires on its own" "$(at 200000 cooldown eligible --order claude)" "claude"
at 200000 cooldown clear --provider claude
expect "a verified success resets the strikes" "$(at 200001 cooldown record --provider claude --reason x)" $'\t3600'
leftover="$(find "$AGENT_POOL_STATE/cooldowns" -name '.*.json.*' | wc -l)"
expect "atomic writes leave no temp files behind" "$leftover" "0"
at 10000 cooldown fault --provider cursor --reason "denied"
expect "a setup fault is recorded" "$(cat "$AGENT_POOL_STATE/faults/cursor.json")" '"reason": "denied"'
expect "a setup fault is not a cooldown" "$(at 10001 cooldown eligible --order cursor)" "cursor"

echo
echo "classification"
classify() { # provider rc stdout [stderr]
  printf '%s' "$3" > "$TMP/o"; printf '%s' "${4:-}" > "$TMP/e"
  python3 "$SCRIPTS/classify.py" --provider "$1" --exit "$2" --stdout "$TMP/o" --stderr "$TMP/e"
}
expect "claude credit wall" "$(classify claude 0 '{"type":"result","subtype":"success","is_error":true,"result":"Credit balance is too low"}')" "limit"
expect "claude PARKED usage dialog" "$(classify claude 1 '' "You've reached your usage limit")" "limit"
expect "claude permission_denials is a setup fault" "$(classify claude 0 '{"subtype":"success","is_error":false,"result":"done","permission_denials":[{"tool_name":"Bash"}]}')" "setup"
expect "claude success" "$(classify claude 0 '{"subtype":"success","is_error":false,"result":"done","permission_denials":[]}')" "ok"
expect "a successful review that discusses rate limits is not a limit" \
  "$(classify claude 0 '{"subtype":"success","is_error":false,"result":"Reviewed the retry code: it handles HTTP 429 and rate limit headers, and quota exceeded errors, correctly. Nothing else to add here, the change is sound and well tested overall, with clear naming, focused commits, consistent error types, documented edge cases, and a changelog entry that matches what the code does. Posted the review comment with the marker as requested."}')" "ok"
CURSOR_DENIED='{"type":"tool_call","subtype":"completed","tool_call":{"shellToolCall":{"result":{"permissionDenied":{"reason":"deny"}}}}}
{"type":"result","subtype":"success","is_error":false,"result":"done"}'
expect "cursor permissionDenied is a setup fault despite exit 0" "$(classify cursor 0 "$CURSOR_DENIED")" "setup"
CURSOR_REJECTED='{"type":"tool_call","subtype":"completed","tool_call":{"editToolCall":{"result":{"rejected":{"reason":"user"}}}}}
{"type":"result","subtype":"success","is_error":false,"result":"done"}'
expect "cursor rejected is a setup fault" "$(classify cursor 0 "$CURSOR_REJECTED")" "setup"
expect "cursor with no result event is incomplete" "$(classify cursor 0 '{"type":"system","subtype":"init"}')" "incomplete"
expect "cursor with no result event and a rate limit is a limit" "$(classify cursor 1 '{"type":"system"}' 'Error: rate limit exceeded')" "limit"
expect "cursor success" "$(classify cursor 0 '{"type":"result","subtype":"success","is_error":false,"result":"ok"}')" "ok"
expect "grok 429" "$(classify grok 1 '' 'HTTP 429 Too Many Requests')" "limit"
expect "grok success" "$(classify grok 0 '{"text":"done","stopReason":"EndTurn"}')" "ok"
expect "agy denied_actions is a setup fault despite SUCCESS" "$(classify agy 0 '{"status":"SUCCESS","denied_actions":[{"tool":"run_command"}]}')" "setup"
expect "agy quota exceeded" "$(classify agy 1 '{"status":"ERROR","error":"Quota exceeded for model"}')" "limit"
expect "agy hitting WORKER_TIMEOUT is a timeout, not incomplete" "$(classify agy 124 '')" "timeout"
expect "a killed run (137) is a timeout" "$(classify claude 137 '')" "timeout"
expect "a timeout with limit wording is still a limit" "$(classify grok 124 '' 'rate limit exceeded')" "limit"
expect "codex insufficient credits" "$(classify codex 1 '' 'insufficient credits')" "limit"
expect "a missing binary is a setup fault" "$(classify grok 127 '' 'not found')" "setup"
expect "RESOURCE_EXHAUSTED is a limit" "$(classify agy 1 '{"status":"ERROR","error":"RESOURCE_EXHAUSTED: try later"}')" "limit"
expect "usage limit wording is a limit" "$(classify codex 1 '' 'You have reached your usage limit for today')" "limit"
expect "'hit your ... limit' is a limit" "$(classify grok 1 '' 'You hit your weekly limit')" "limit"
expect "a short successful agy result with RESOURCE_EXHAUSTED is a limit" \
  "$(classify agy 0 '{"status":"SUCCESS","response":"RESOURCE_EXHAUSTED"}')" "limit"
expect "a short successful cursor result with usage-limit wording is a limit" \
  "$(classify cursor 0 '{"type":"result","subtype":"success","is_error":false,"result":"You hit your usage limit."}')" "limit"
expect "a short successful grok result with insufficient credits is a limit" \
  "$(classify grok 0 '{"text":"Insufficient credits"}')" "limit"
expect "a short successful codex result with too many requests is a limit" "$(classify codex 0 'Too many requests')" "limit"
expect "a short successful cursor credit wall is a limit" \
  "$(classify cursor 0 '{"type":"result","subtype":"success","is_error":false,"result":"Credit balance is too low"}')" "limit"
AGY_OK='{"status":"SUCCESS","conversation_id":"conv-42","response":"## Automated review\nnothing\n<!-- pulse-review:v1 head=abc findings=0 -->"}'
expect "agy SUCCESS with a response is ok" "$(classify agy 0 "$AGY_OK")" "ok"
expect "agy conversation_id is reported as the session" "$(classify agy 0 "$AGY_OK" | cut -f3)" "conv-42"
printf '%s' "$AGY_OK" > "$TMP/o"; : > "$TMP/e"
python3 "$SCRIPTS/classify.py" --provider agy --exit 0 --stdout "$TMP/o" --stderr "$TMP/e" --result-out "$TMP/r" >/dev/null
expect "agy response is written to --result-out" "$(cat "$TMP/r")" "pulse-review:v1 head=abc findings=0"
expect "claude session_id is reported" "$(classify claude 0 '{"subtype":"success","is_error":false,"result":"done","session_id":"s-1"}' | cut -f3)" "s-1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
