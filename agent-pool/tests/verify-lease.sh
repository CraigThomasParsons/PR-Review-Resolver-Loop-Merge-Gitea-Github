#!/usr/bin/env bash
# Offline unit cases for the agent pool's claim records, holds, cooldowns, limit classification,
# prompt rendering and worker permission policy. A pinned clock (AGENT_POOL_NOW) steps across
# deadlines and cooldowns; nothing sleeps, nothing touches the network, and all state lives in a
# temp directory.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="$ROOT/agent-pool/scripts"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export AGENT_POOL_STATE="$TMP/state"
R=owner/repo

claimrec() { python3 "$SCRIPTS/claim-record.py" "$@"; }
cooldown() { python3 "$SCRIPTS/cooldown.py" "$@"; }
at() { local t="$1"; shift; AGENT_POOL_NOW="$t" "$@"; }

pass=0; fail=0
expect() { # name got wanted-substring
  if [[ "$2" == *"$3"* ]]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n         wanted *%s*\n         got %s\n' "$1" "$3" "$2"; fi
}
expect_not() { # name got unwanted-substring
  if [[ "$2" != *"$3"* ]]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n         did not want *%s*\n         got %s\n' "$1" "$3" "$2"; fi
}
expect_rc() { # name got-rc wanted-rc
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n         wanted exit %s, got %s\n' "$1" "$3" "$2"; fi
}

# A stub Gitea adapter for the label reads and flips reconcile and requeue make.
cat > "$TMP/adapter.py" <<'PY'
import json, os, sys
path = os.environ["STUB_LABELS"]
a = sys.argv[1:]
arg = lambda n: a[a.index(n) + 1] if n in a else None
labels = json.load(open(path)) if os.path.exists(path) else {}
pr = arg("--pr")
if a[0] == "labels":
    print(json.dumps(labels.get(pr, [])))
elif a[0] == "label":
    if os.environ.get("STUB_LABEL_FAIL"):
        sys.exit("stub: label write failed")
    cur = [l for l in labels.get(pr, []) if l not in (arg("--remove") or "").split(",")]
    cur += [x for x in (arg("--add") or "").split(",") if x and x not in cur]
    labels[pr] = cur
    json.dump(labels, open(path, "w"))
    print("stub label output that must not leak into the attempt id")
PY
export STUB_LABELS="$TMP/labels.json"
AD="$TMP/adapter.py"
setlabels() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])) if __import__("os").path.exists(sys.argv[1]) else {}; d[sys.argv[2]]=json.loads(sys.argv[3]); json.dump(d,open(sys.argv[1],"w"))' "$STUB_LABELS" "$1" "$2"; }
getlabels() { python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1])).get(sys.argv[2],[])))' "$STUB_LABELS" "$1"; }
field() { python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"; }
FLIP=(-- python3 "$AD" label --repo $R --pr 7 --remove agent:ready --add agent:claimed)

echo "write-once claim records keyed by attempt_id"
setlabels 7 '["agent:ready"]'
a1="$(at 1000 claimrec claim --repo $R --pr 7 --worker w1 --provider claude --job review --branch feature/x \
  --deadline-secs 100 "${FLIP[@]}")"
expect "a claim prints a uuid4 attempt_id" "$a1" "-4"
expect_not "the label command's stdout does not leak into the attempt id" "$a1" "stub"
expect "the claim flipped the label" "$(getlabels 7)" "agent:claimed"
rec="$(claimrec show --repo $R --pr 7)"
expect "the record is schema version 2" "$(field version <<<"$rec")" "2"
expect "the record carries the attempt_id" "$(field attempt_id <<<"$rec")" "$a1"
expect "the record names the provider" "$(field provider <<<"$rec")" "claude"
expect "claimed_at is ISO Z" "$(field claimed_at <<<"$rec")" "1970-01-01T00:16:40Z"
expect "expected_deadline_at is absolute, claim time plus the deadline" "$(field expected_deadline_at <<<"$rec")" "1970-01-01T00:18:20Z"
expect_not "there is no renewable expiry or fence counter" "$rec" "expires_at"
at 1050 claimrec claim --repo $R --pr 7 --worker w2 --provider grok "${FLIP[@]}" 2>/dev/null
expect_rc "a second claim is refused while a record exists" "$?" 3
expect "and the record is unchanged (write-once)" "$(claimrec show --repo $R --pr 7 | field attempt_id)" "$a1"

at 1050 claimrec check --repo $R --pr 7 --attempt "$a1"
expect_rc "the current attempt checks out" "$?" 0
at 1050 claimrec check --repo $R --pr 7 --attempt not-the-attempt 2>/dev/null
expect_rc "any other attempt_id is not current" "$?" 4
at 1050 claimrec guard --repo $R --pr 7 --attempt "$a1" -- touch "$TMP/fresh-write"
[ -e "$TMP/fresh-write" ] && got=ran || got=not-run
expect "the current attempt's guarded write runs" "$got" "ran"

echo
echo "fallback is a new attempt naming the provider actually used"
a2="$(at 1060 claimrec reattempt --repo $R --pr 7 --attempt "$a1" --provider cursor --deadline-secs 100)"
rec="$(claimrec show --repo $R --pr 7)"
expect "reattempt issues a fresh attempt_id" "$(field attempt_id <<<"$rec")" "$a2"
expect_not "different from the first" "$a2" "$a1"
expect "the record names the fallback provider" "$(field provider <<<"$rec")" "cursor"
expect "and records which attempt it superseded" "$(field supersedes <<<"$rec")" "$a1"
expect "the worker id carries over" "$(field worker_id <<<"$rec")" "w1"
expect "the new attempt has its own deadline" "$(field expected_deadline_at <<<"$rec")" "1970-01-01T00:19:20Z"
out="$(at 1061 claimrec guard --repo $R --pr 7 --attempt "$a1" -- touch "$TMP/stale-write" 2>&1)"; rc=$?
expect_rc "the superseded attempt's write is fenced off" "$rc" 4
expect "the blocked write says why" "$out" "superseded by $a2"
[ -e "$TMP/stale-write" ] && got=ran || got=not-run
expect "the blocked command never ran" "$got" "not-run"
at 1061 claimrec reattempt --repo $R --pr 7 --attempt "$a1" --provider grok 2>/dev/null
expect_rc "a superseded attempt cannot reattempt" "$?" 4
at 1061 claimrec release --repo $R --pr 7 --attempt "$a1" -- touch "$TMP/stale-release" 2>/dev/null
expect_rc "a superseded attempt cannot release" "$?" 4
[ -e "$TMP/stale-release" ] && got=ran || got=not-run
expect "and its release label flip never ran" "$got" "not-run"

echo
echo "staleness is now > expected_deadline_at, nothing else"
at 1160 claimrec requeue --repo $R --pr 7 --attempt "$a2" --adapter "$AD" 2>/dev/null
expect_rc "exactly at the deadline the attempt is not stale" "$?" 4
expect "so nothing was relabelled" "$(getlabels 7)" "agent:claimed"
expect "reconcile before the deadline says live" "$(at 1159 claimrec reconcile --repo $R --pr 7 --adapter "$AD")" "live"
expect "reconcile at the deadline still says live" "$(at 1160 claimrec reconcile --repo $R --pr 7 --adapter "$AD")" "live"
expect "reconcile one second after says stale" "$(at 1161 claimrec reconcile --repo $R --pr 7 --adapter "$AD")" "stale"
out="$(at 1161 claimrec requeue --repo $R --pr 7 --attempt "$a2" --adapter "$AD")"
expect "requeue names the stale provider for its cooldown" "$out" "cursor"
expect "requeue flips claimed back to ready" "$(getlabels 7)" "agent:ready"
expect "and deletes the record" "$(claimrec show --repo $R --pr 7)" "{}"

echo
echo "release: label first, then the record"
setlabels 7 '["agent:ready"]'
a3="$(at 2000 claimrec claim --repo $R --pr 7 --worker w1 --provider claude "${FLIP[@]}")"
STUB_LABEL_FAIL=1 at 2001 claimrec release --repo $R --pr 7 --attempt "$a3" \
  -- python3 "$AD" label --repo $R --pr 7 --remove agent:claimed --add agent:done 2>/dev/null
expect_rc "a failed release flip reports failure" "$?" 1
expect "and keeps the record for reconciliation" "$(claimrec show --repo $R --pr 7 | field attempt_id)" "$a3"
at 2002 claimrec release --repo $R --pr 7 --attempt "$a3" -- python3 "$AD" label --repo $R --pr 7 --remove agent:claimed --add agent:done
expect_rc "the holder releases" "$?" 0
expect "the release flipped the label" "$(getlabels 7)" "agent:done"
expect "then deleted the record" "$(claimrec show --repo $R --pr 7)" "{}"
at 2003 claimrec guard --repo $R --pr 7 --attempt "$a3" -- true 2>/dev/null
expect_rc "a released attempt authorises no more writes" "$?" 4
setlabels 7 '["agent:ready"]'
STUB_LABEL_FAIL=1 at 2004 claimrec claim --repo $R --pr 7 --worker w1 --provider claude "${FLIP[@]}" 2>/dev/null
expect_rc "a claim whose label flip fails exits 5" "$?" 5
expect "and its record is rolled back" "$(claimrec show --repo $R --pr 7)" "{}"

echo
echo "reconcile (issue #1's table, against live labels)"
setlabels 11 '["agent:claimed"]'
expect "claimed with no record goes to needs-human" "$(at 3000 claimrec reconcile --repo $R --pr 11 --adapter "$AD")" "needs-human"
expect "the label really moved" "$(getlabels 11)" "agent:needs-human"
setlabels 12 '["agent:ready"]'
at 3000 claimrec claim --repo $R --pr 12 --worker w1 --provider claude >/dev/null
setlabels 12 '["agent:done"]'
expect "a record whose label is no longer claimed is dropped" "$(at 3001 claimrec reconcile --repo $R --pr 12 --adapter "$AD")" "orphan-dropped"
expect "the orphan record is gone" "$(claimrec show --repo $R --pr 12)" "{}"
setlabels 13 '["agent:ready"]'
expect "no label, no record is free" "$(at 3002 claimrec reconcile --repo $R --pr 13 --adapter "$AD")" "free"
echo '{not json' > "$AGENT_POOL_STATE/claims/owner_repo__14.json"
setlabels 14 '["agent:claimed"]'
expect "an unreadable record under a claimed label goes to needs-human" "$(at 3003 claimrec reconcile --repo $R --pr 14 --adapter "$AD")" "needs-human"

echo
echo "hold state (GiteaFence::issueHeldByHuman without the permanent hold)"
H=(--hold-labels "status: in-progress" --bot pool-bot)
setlabels 7 '["agent:ready"]'
a4="$(at 4000 claimrec claim --repo $R --pr 7 --worker w1 --provider claude --deadline-secs 100)"
at 4050 claimrec hold --repo $R --pr 7 --labels '["agent:claimed"]' "${H[@]}" > "$TMP/h"
expect "a live claim is a bot hold" "$(cat "$TMP/h")" "live"
at 4050 claimrec hold --repo $R --pr 8 --labels '["agent:ready"]' --assignees '["craig"]' "${H[@]}" > "$TMP/h"
expect "a human assignee is a human hold" "$(cat "$TMP/h")" "human"
at 4050 claimrec hold --repo $R --pr 8 --labels '["agent:ready","agent:needs-human"]' "${H[@]}" > "$TMP/h"
expect "an agent:needs-human label is a human hold" "$(cat "$TMP/h")" "human"
at 4050 claimrec hold --repo $R --pr 8 --labels '["agent:ready"]' --assignees '["pool-bot"]' "${H[@]}" > "$TMP/h"
expect "the bot's own assignment is not a human hold" "$(cat "$TMP/h")" "free"
at 5000 claimrec hold --repo $R --pr 8 --labels '["status: in-progress"]' --grace 600 "${H[@]}" > "$TMP/h"
expect "status: in-progress with no claim starts a grace period" "$(cat "$TMP/h")" "hold-pending"
at 5599 claimrec hold --repo $R --pr 8 --labels '["status: in-progress"]' --grace 600 "${H[@]}" > "$TMP/h"
expect "inside the grace period it is still pending, not human" "$(cat "$TMP/h")" "hold-pending"
at 5600 claimrec hold --repo $R --pr 8 --labels '["status: in-progress"]' --grace 600 "${H[@]}" > "$TMP/h"
expect "after the grace period the orphan hold has expired" "$(cat "$TMP/h")" "hold-expired"
at 5601 claimrec hold --repo $R --pr 8 --labels '["agent:ready"]' --grace 600 "${H[@]}" > /dev/null
at 5602 claimrec hold --repo $R --pr 8 --labels '["status: in-progress"]' --grace 600 "${H[@]}" > "$TMP/h"
expect "a hold that went away and came back starts its grace again" "$(cat "$TMP/h")" "hold-pending"

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

echo
echo "prompt rendering"
printf 'branch __HEADREF__ pr __PR__ report __REPORT__ again __HEADREF__\n' > "$TMP/tpl"
python3 "$SCRIPTS/render-prompt.py" "$TMP/tpl" "$TMP/rendered" 'HEADREF=feat/a|b&c\1' 'PR=7' 'REPORT=/tmp/r&|.md'
expect "| & and backslashes in a branch name survive rendering" "$(cat "$TMP/rendered")" 'branch feat/a|b&c\1 pr 7 report /tmp/r&|.md again feat/a|b&c\1'
expect "no placeholder is left" "$(grep -c '__[A-Z]*__' "$TMP/rendered")" "0"
python3 "$SCRIPTS/render-prompt.py" "$TMP/tpl" "$TMP/rendered" 'NOEQUALS' 2>/dev/null
expect_rc "a malformed KEY=VALUE is refused" "$?" "1"

echo
echo "report checks (L2: no credentials in a posted report)"
MARKER_PY="$ROOT/skills/pr-loops-common/marker.py"
SHA40=0123456789abcdef0123456789abcdef01234567
mkdir -p "$TMP/home/.config/pulse"; printf 'fixturetoken-%s\n' 4f1c9e2a7b > "$TMP/home/.config/pulse/gitea_token"
rep() { # body -> report.py review verdict, with a sandboxed HOME and no GITEA_TOKEN
  printf '%s\n<!-- pulse-review:v1 head=%s findings=0 -->\n' "$1" "$SHA40" > "$TMP/rep.md"
  HOME="$TMP/home" env -u GITEA_TOKEN python3 "$SCRIPTS/report.py" review --marker-module "$MARKER_PY" \
    --file "$TMP/rep.md" --sha "$SHA40" | cut -f1
}
expect "a clean review report is ok" "$(rep 'Looks good. Commit 89abcdef0123456789abcdef0123456789abcdef is fine.')" "ok"
expect "the adapter's token file contents are refused" "$(rep 'debug: fixturetoken-4f1c9e2a7b')" "invalid"
expect "GITEA_TOKEN from the environment is refused" "$(printf 'x\n<!-- pulse-review:v1 head=%s findings=0 -->\n' "$SHA40" > "$TMP/rep2.md"; \
  echo 'leak envtoken-77aa' >> "$TMP/rep2.md"; HOME="$TMP/home" GITEA_TOKEN=envtoken-77aa python3 "$SCRIPTS/report.py" review \
  --marker-module "$MARKER_PY" --file "$TMP/rep2.md" --sha "$SHA40" | cut -f1)" "invalid"
expect "a private key header is refused" "$(rep '-----BEGIN OPENSSH PRIVATE KEY-----')" "invalid"
expect "a GitHub token shape is refused" "$(rep 'ghp_abcdefghijklmnopqrstuvwxyz0123456789')" "invalid"
expect "an Anthropic key shape is refused" "$(rep 'sk-ant-api03-abcdefghijklmnopqrstuvwx')" "invalid"
expect "an AWS key id is refused" "$(rep 'AKIAABCDEFGHIJKLMNOP')" "invalid"
expect "'token <40 hex>' is refused" "$(rep "Authorization: token $SHA40")" "invalid"

echo
echo "worker permission policy"
AD_ABS=/opt/pool/skills/pr-loops-common/gitea-pr.py
pol() { # family job command
  python3 "$SCRIPTS/policy.py" check --family "$1" --job "$2" --adapter "$AD_ABS" --worktree /wt --report /runs/r.md -- "$3"
}
for fam in glob prefix; do
  for job in review resolve; do
    expect "$fam/$job: git push HEAD:main is denied" "$(pol $fam $job 'git push origin HEAD:main')" deny
    expect "$fam/$job: a + refspec push is denied" "$(pol $fam $job 'git push origin +HEAD:refs/heads/feature/x')" deny
    expect "$fam/$job: a trailing -f push is denied" "$(pol $fam $job 'git push origin feature/x -f')" deny
    expect "$fam/$job: any worker push is denied" "$(pol $fam $job 'git push origin HEAD:refs/heads/feature/x')" deny
    expect "$fam/$job: git -C . push --force is denied" "$(pol $fam $job 'git -C . push --force')" deny
    expect "$fam/$job: a relative-path adapter comment is denied" "$(pol $fam $job 'python3 ./gitea-pr.py comment --repo o/r --pr 1 --body-file x')" deny
    expect "$fam/$job: a bare adapter label is denied" "$(pol $fam $job 'python3 gitea-pr.py label --repo o/r --pr 1 --add x')" deny
    expect "$fam/$job: the absolute adapter's comment is denied" "$(pol $fam $job "python3 $AD_ABS comment --repo o/r --pr 1 --body-file x")" deny
    expect "$fam/$job: python3 -c is denied" "$(pol $fam $job "python3 -c 'import os'")" deny
    expect "$fam/$job: an arbitrary python3 script is denied" "$(pol $fam $job 'python3 /tmp/x.py')" deny
    expect "$fam/$job: node -e is denied" "$(pol $fam $job "node -e 'x'")" deny
    expect "$fam/$job: git reset --hard is denied" "$(pol $fam $job 'git reset --hard HEAD~1')" deny
    expect "$fam/$job: git merge is denied" "$(pol $fam $job 'git merge origin/master')" deny
    expect "$fam/$job: git add -A is denied" "$(pol $fam $job 'git add -A')" deny
    expect "$fam/$job: curl is denied" "$(pol $fam $job 'curl https://example.invalid')" deny
    expect "$fam/$job: a push hidden behind && is denied" "$(pol $fam $job 'git status && git push origin HEAD:main')" deny
    expect "$fam/$job: the adapter's head read is allowed" "$(pol $fam $job "python3 $AD_ABS head --repo o/r --pr 1")" allow
    expect "$fam/$job: the adapter's threads read is allowed" "$(pol $fam $job "python3 $AD_ABS threads --repo o/r --pr 1")" allow
    expect "$fam/$job: git diff is allowed" "$(pol $fam $job 'git diff origin/master...HEAD')" allow
    expect "$fam/$job: a read pipeline is allowed" "$(pol $fam $job 'git log --oneline | head -5')" allow
  done
  expect "$fam/review: staging is denied" "$(pol $fam review 'git add src/a.php')" deny
  expect "$fam/review: committing is denied" "$(pol $fam review 'git commit -m x')" deny
  expect "$fam/review: running the gate is not allowed" "$(pol $fam review 'npm test')" deny
  expect "$fam/resolve: staging a named path is allowed" "$(pol $fam resolve 'git add src/a.php tests/b.php')" allow
  expect "$fam/resolve: a commit -m is allowed" "$(pol $fam resolve 'git commit -m "fix: x"')" allow
  expect "$fam/resolve: the gate is allowed" "$(pol $fam resolve 'npm run test')" allow
  expect "$fam/resolve: git commit --amend is denied" "$(pol $fam resolve 'git commit --amend -m x')" deny
  expect "$fam/resolve: git commit -a is denied" "$(pol $fam resolve 'git commit -a -m x')" deny
done
for fam in glob prefix; do
  for job in review resolve; do
    # Review G1: argument-level bypasses of the old globs.
    expect "$fam/$job: git difftool -x is denied" "$(pol $fam $job "git difftool -y -x 'touch /tmp/pwned'")" deny
    expect "$fam/$job: git difftool --extcmd is denied" "$(pol $fam $job "git difftool --extcmd=sh HEAD")" deny
    expect "$fam/$job: git diff --ext-diff is denied" "$(pol $fam $job 'git diff --ext-diff HEAD~1')" deny
    expect "$fam/$job: git diff --textconv is denied" "$(pol $fam $job 'git diff --textconv HEAD~1')" deny
    expect "$fam/$job: git log --output= is denied" "$(pol $fam $job 'git log --output=/tmp/x')" deny
    expect "$fam/$job: git show --output <file> is denied" "$(pol $fam $job 'git show --output /tmp/x HEAD')" deny
    expect "$fam/$job: git diff --output is denied" "$(pol $fam $job 'git diff --output=/tmp/x')" deny
    expect "$fam/$job: git -c core.pager is denied" "$(pol $fam $job "git -c core.pager='sh -c x' log")" deny
    expect "$fam/$job: git --git-dir is denied" "$(pol $fam $job 'git --git-dir=/tmp/g log')" deny
    expect "$fam/$job: git grep -O is denied" "$(pol $fam $job 'git grep -Ovim foo')" deny
    expect "$fam/$job: an unknown git subcommand is denied" "$(pol $fam $job 'git archive HEAD')" deny
    expect "$fam/$job: an unvetted git option is denied" "$(pol $fam $job 'git log --exec=x')" deny
    expect "$fam/$job: rg --pre is denied" "$(pol $fam $job 'rg --pre ./x pattern')" deny
    expect "$fam/$job: rg -z is denied" "$(pol $fam $job 'rg -z pattern')" deny
    expect "$fam/$job: tail -f is denied" "$(pol $fam $job 'tail -f log.txt')" deny
    for redir in 'cat a > /tmp/x' 'cat a >> /tmp/x' 'wc -l < /etc/passwd' 'git log 2> /tmp/x' \
                 'git log &> /tmp/x' 'git log >&2' 'git status > /dev/null' 'git log -p>out'; do
      expect "$fam/$job: redirection '$redir' is denied" "$(pol $fam $job "$redir")" deny
    done
    expect "$fam/$job: background & is denied" "$(pol $fam $job 'git log & git push')" deny
    expect "$fam/$job: a subshell is denied" "$(pol $fam $job '(git status)')" deny
    expect "$fam/$job: backticks are denied" "$(pol $fam $job 'cat `which x`')" deny
    expect "$fam/$job: a newline-separated second command is checked" "$(pol $fam $job $'git status\ngit push origin x')" deny
    expect "$fam/$job: an unbalanced quote is denied" "$(pol $fam $job "git log --grep='x")" deny
    # Review L2: credential paths.
    expect "$fam/$job: reading ~/.ssh is denied" "$(pol $fam $job 'cat ~/.ssh/id_ed25519')" deny
    expect "$fam/$job: reading the tea config is denied" "$(pol $fam $job 'cat ~/.config/tea/config.yml')" deny
    expect "$fam/$job: reading the adapter's token file is denied" "$(pol $fam $job 'cat ~/.config/pulse/gitea_token')" deny
    expect "$fam/$job: reading /proc environ is denied" "$(pol $fam $job 'cat /proc/self/environ')" deny
    expect "$fam/$job: grepping ~/.netrc is denied" "$(pol $fam $job 'grep -r token ~/.netrc')" deny
    expect "$fam/$job: the adapter's comments read is allowed" "$(pol $fam $job "python3 $AD_ABS comments --repo o/r --pr 1")" allow
    expect "$fam/$job: the adapter with extra arguments is denied" "$(pol $fam $job "python3 $AD_ABS head --repo o/r --pr 1 --base-url x")" deny
    expect "$fam/$job: a quoted | inside an argument is not a pipe" "$(pol $fam $job "git log --grep='a|b' -n 3")" allow
    expect "$fam/$job: git status --porcelain is allowed" "$(pol $fam $job 'git status --porcelain')" allow
    expect "$fam/$job: git show with a format is allowed" "$(pol $fam $job 'git show --stat --format=%H HEAD')" allow
    expect "$fam/$job: rg with a glob is allowed" "$(pol $fam $job "rg -n -g '*.php' foo src")" allow
  done
  # Review S3: forced adds and tool configuration.
  expect "$fam/resolve: git add -f is denied" "$(pol $fam resolve 'git add -f .cursor/cli.json')" deny
  expect "$fam/resolve: git add --force is denied" "$(pol $fam resolve 'git add --force src/a.php')" deny
  expect "$fam/resolve: a trailing -f on git add is denied" "$(pol $fam resolve 'git add src/a.php -f')" deny
  expect "$fam/resolve: staging .cursor/ is denied" "$(pol $fam resolve 'git add .cursor/cli.json')" deny
  expect "$fam/resolve: staging .grok/ is denied" "$(pol $fam resolve 'git add .grok/settings.json')" deny
  expect "$fam/resolve: git add -p is denied" "$(pol $fam resolve 'git add -p')" deny
  expect "$fam/resolve: git commit without a message is denied" "$(pol $fam resolve 'git commit')" deny
  expect "$fam/resolve: git commit with paths is denied" "$(pol $fam resolve 'git commit -m x src/a.php')" deny
  expect "$fam/resolve: npm test 2>&1 is denied (redirection is its own segment)" "$(pol $fam resolve 'npm test 2>&1')" deny
  expect "$fam/resolve: a gate piped into tail is allowed" "$(pol $fam resolve 'npm test | tail -50')" allow
done
expect "glob: git commit -m x --amend is denied" "$(pol glob resolve 'git commit -m x --amend')" deny
expect "glob: command substitution is denied" "$(pol glob resolve 'cat $(curl https://example.invalid)')" deny
expect "glob: rg --pre is denied" "$(pol glob review 'rg --pre ./x pattern')" deny
for prov in claude grok cursor; do
  rules="$(python3 "$SCRIPTS/policy.py" rules --provider $prov --job resolve --adapter "$AD_ABS" --worktree /wt --report /runs/r.md)"
  expect "$prov keeps an explicit deny for git push --force" "$rules" "deny"$'\t'"$([ $prov = cursor ] && echo 'Shell(git push --force)' || echo 'Bash(git push --force*)')"
  expect "$prov keeps an explicit deny for git reset --hard" "$rules" "$([ $prov = cursor ] && echo 'Shell(git reset --hard)' || echo 'Bash(git reset --hard*)')"
  expect "$prov keeps an explicit deny for git merge" "$rules" "$([ $prov = cursor ] && echo 'Shell(git merge)' || echo 'Bash(git merge*)')"
  allows="$(printf '%s\n' "$rules" | grep '^allow')"
  expect_not "$prov allows no python3 *" "$allows" "python3 *)"
  expect_not "$prov allows no node" "$allows" "node"
  expect_not "$prov allows no npx" "$allows" "npx"
  expect_not "$prov allows no git push" "$allows" "git push"
done
cursor_allows="$(python3 "$SCRIPTS/policy.py" rules --provider cursor --job resolve --adapter "$AD_ABS" --worktree /wt --report /runs/r.md | grep '^allow')"
expect_not "cursor has no broad Shell(git) allow" "$cursor_allows" $'\tShell(git)'
expect_not "cursor has no broad Shell(python3) allow" "$cursor_allows" $'\tShell(python3)'
expect "cursor allows the adapter's reads by absolute path" "$cursor_allows" "Shell(python3 $AD_ABS head)"
python3 "$SCRIPTS/policy.py" cursor-json --job review --adapter "$AD_ABS" --worktree /wt --report /runs/r.md | python3 -c 'import json,sys; json.load(sys.stdin)'
expect_rc "cursor-json is valid JSON" "$?" 0

rules_of() { python3 "$SCRIPTS/policy.py" rules --provider "$1" --job "$2" --adapter "$AD_ABS" --worktree /wt --report /runs/r.md; }
for prov in claude grok; do
  r="$(rules_of $prov review)"
  expect "$prov emits git diff and git diff * separately" "$r" "Bash(git diff *)"
  expect_not "$prov no longer emits a bare git diff* glob" "$r" "Bash(git diff*)"
  expect "$prov denies git difftool" "$r" "Bash(git difftool*)"
  expect "$prov denies --output" "$r" "Bash(*--output*)"
  expect "$prov denies redirection" "$r" "Bash(*>*)"
  expect "$prov denies git add -f" "$(rules_of $prov resolve)" "Bash(git add -f*)"
  expect "$prov denies credential reads" "$r" "Read("
done
# Review G2 and L1: writes scoped per job, .git never writable.
r="$(rules_of claude review)"
expect "claude review may write its report by absolute path" "$r" $'allow\tWrite(//runs/r.md)'
expect_not "claude review has no bare Write" "$r" $'allow\tWrite\n'
expect_not "claude review cannot edit" "$r" $'allow\tEdit'
r="$(rules_of claude resolve)"
expect "claude resolve may edit the worktree" "$r" $'allow\tEdit(//wt/**)'
expect "claude resolve may write the worktree" "$r" $'allow\tWrite(//wt/**)'
expect_not "claude resolve has no unscoped MultiEdit" "$r" $'allow\tMultiEdit'
expect "claude denies the worktree's .git pointer" "$r" $'deny\tWrite(//wt/.git)'
expect "claude denies any .git directory" "$r" $'deny\tEdit(**/.git/**)'
expect "claude denies reading ~/.ssh" "$r" "deny"$'\t'"Read(/$HOME/.ssh/**)"
r="$(rules_of cursor review)"
expect "cursor review may write only its report" "$r" $'allow\tWrite(/runs/r.md)'
expect_not "cursor review has no Write(**)" "$r" "Write(**)"
r="$(rules_of cursor resolve)"
expect "cursor resolve writes are scoped to the worktree" "$r" $'allow\tWrite(/wt/**)'
expect "cursor denies the worktree's .git" "$r" $'deny\tWrite(/wt/.git/**)'
expect "grok denies the worktree's .git" "$(rules_of grok resolve)" $'deny\tWrite(/wt/.git)'
hk() { # job event-json
  printf '%s' "$2" | python3 "$SCRIPTS/policy.py" hook --job "$1" --adapter "$AD_ABS" --worktree /wt --report /runs/r.md 2>/dev/null
}
hk review '{"tool_name":"Bash","tool_input":{"command":"git log --oneline"}}'
expect_rc "claude hook: an allowed read passes" "$?" 0
hk review '{"tool_name":"Bash","tool_input":{"command":"git difftool -y -x sh"}}'
expect_rc "claude hook: git difftool is blocked (exit 2)" "$?" 2
hk review '{"tool_name":"Bash","tool_input":{"command":"cat a > /tmp/x"}}'
expect_rc "claude hook: redirection is blocked" "$?" 2
hk review '{"tool_name":"Write","tool_input":{"file_path":"/runs/r.md"}}'
expect_rc "claude hook: review may write its report" "$?" 0
hk review '{"tool_name":"Write","tool_input":{"file_path":"/wt/src/a.php"}}'
expect_rc "claude hook: review may not write the worktree" "$?" 2
hk resolve '{"tool_name":"Edit","tool_input":{"file_path":"/wt/src/a.php"}}'
expect_rc "claude hook: resolve may edit the worktree" "$?" 0
hk resolve '{"tool_name":"Write","tool_input":{"file_path":"/wt/.git"}}'
expect_rc "claude hook: resolve may not write the .git pointer" "$?" 2
hk resolve '{"tool_name":"Edit","tool_input":{"file_path":"/wt/.cursor/cli.json"}}'
expect_rc "claude hook: resolve may not edit tool configuration" "$?" 2
hk resolve '{"tool_name":"Write","tool_input":{"file_path":"/opt/pool/agent-pool/scripts/policy.py"}}'
expect_rc "claude hook: resolve may not write outside the worktree" "$?" 2
hk review '{"tool_name":"Read","tool_input":{"file_path":"'"$HOME"'/.ssh/id_rsa"}}'
expect_rc "claude hook: reading ~/.ssh is blocked" "$?" 2
hk review '{"tool_name":"Read","tool_input":{"file_path":"/wt/README.md"}}'
expect_rc "claude hook: reading the worktree passes" "$?" 0
hs="$(python3 "$SCRIPTS/policy.py" hook-settings --job review --adapter "$AD_ABS" --worktree /wt --report /runs/r.md)"
expect "hook-settings wires a PreToolUse hook" "$hs" '"PreToolUse"'
expect "that runs policy.py hook for this job" "$hs" "policy.py hook --job review"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
