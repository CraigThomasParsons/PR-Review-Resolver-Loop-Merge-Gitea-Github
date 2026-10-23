#!/usr/bin/env bash
# Offline cases for the usage-limit fallback: classify-pane.sh's RATE_LIMITED and EXITED states,
# provider-fallback.py's reset parsing, limit memory and Agy result reading, and whole pr-loop.sh
# ticks in which a Claude worker hits its limit and the review is rerun under Agy.
#
# Everything runs under a temporary HOME. claude, agy, tea, tmux and git are stubs on PATH; the
# Gitea adapter is a stub over a JSON file; marker.py, classify-pane.sh and provider-fallback.py
# are the real ones. The tmux stub never runs the launch script: each session's pane shows a
# prompt until the loop pastes into it, then "working" twice, then the case's scenario text.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
BIN="$HOME/.local/bin"
mkdir -p "$BIN"
export PATH="$BIN:$PATH"
unset PR_LOOP_PINNED PR_LOOP_PR PR_LOOP_LOCK_WAIT PR_LOOP_STATE PR_LOOP_AGY_BIN PR_LOOP_AGY_MODEL DRY_RUN

SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHA2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; [ $# -lt 2 ] || printf '         %s\n' "${@:2}"; }
expect() { # name condition-command...
  local name="$1"; shift
  if "$@"; then ok "$name"; else no "$name" "condition failed: $*"; fi
}
same() { # name got want
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "wanted: $3" "got:    $2"; fi
}
has() { [[ "$1" == *"$2"* ]]; }
lacks() { [[ "$1" != *"$2"* ]]; }

# ================================================================ classify-pane.sh
echo "classify-pane.sh"
cls() { # pane-text -> state
  printf '%s\n' "$1" > "$TMP/pane.txt"
  CLASSIFY_INPUT_FILE="$TMP/pane.txt" bash "$ROOT/classify-pane.sh" x PR_REVIEW_DONE 40 | head -1
}
MENU=" ⎿  API Error: 429 {\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\"}}

  You've hit your weekly limit · resets Oct 24, 5am (America/Toronto)

  What do you want to do?
  ❯ 1. Stop and wait for limit to reset
    2. Wait here
  Enter to confirm · Esc to cancel"
same "the weekly-limit stop/wait menu is RATE_LIMITED" "$(cls "$MENU")" "STATE=RATE_LIMITED"
same "a bare API 429 on an idle pane is RATE_LIMITED" "$(cls $'  ⎿  API Error: 429 Too Many Requests\n\n> ')" "STATE=RATE_LIMITED"
same "\"usage limit\" on an idle pane is RATE_LIMITED" "$(cls $'Claude usage limit reached. Your limit will reset at 5pm.\n> ')" "STATE=RATE_LIMITED"
same "the old \"You've reached your limit\" dialog is RATE_LIMITED, not PARKED" \
  "$(cls "You've reached your usage limit")" "STATE=RATE_LIMITED"
same "a limit dialog scrolled above the tail is still RATE_LIMITED" \
  "$(cls "$(printf '%s\n' "$MENU"; seq 1 30 | sed 's/^/  waiting /')")" "STATE=RATE_LIMITED"
same "429 in tool output while working stays WORKING" \
  "$(cls $'  ⎿  +  if (res.status === 429) retry(); // usage limit\n✻ Reviewing… (esc to interrupt)')" "STATE=WORKING"
same "a finished review that discusses usage limits is DONE" \
  "$(cls $'The PR adds a usage limit and handles HTTP 429.\nPR_REVIEW_DONE\n> ')" "STATE=DONE"
same "an exited worker with limit text is RATE_LIMITED" \
  "$(cls $'Error: 429 rate limit exceeded\n\nPR_LOOP_WORKER_EXIT=1')" "STATE=RATE_LIMITED"
same "an exited worker without limit text is EXITED" \
  "$(cls $'Error: something broke\n\nPR_LOOP_WORKER_EXIT=1')" "STATE=EXITED"
same "a login dialog is still PARKED" "$(cls 'Select login method:')" "STATE=PARKED"
same "an unknown menu is BLOCKED, never left as IDLE" \
  "$(cls $'Pick one\n❯ 1. Alpha\n  2. Beta\nEnter to confirm')" "STATE=BLOCKED"
same "a plain idle pane is IDLE" "$(cls '> ')" "STATE=IDLE"

# ================================================================ provider-fallback.py
echo
echo "provider-fallback.py"
PF="$ROOT/provider-fallback.py"
FS="$TMP/fstate"
NOW="$(date -u -d '2026-10-23T03:00:00Z' +%s)"
rec() { # text [extra args] -> "<until> <source>"
  printf '%s\n' "$1" > "$TMP/limit.txt"; shift
  python3 "$PF" limit-record --state "$FS" --provider claude --text-file "$TMP/limit.txt" --now "$NOW" "$@" \
    | awk -F'\t' '{print $1, $3}'
}
same "\"resets Oct 24, 5am (America/Toronto)\" is read with its zone" \
  "$(rec "You've hit your weekly limit · resets Oct 24, 5am (America/Toronto)")" \
  "$(TZ=America/Toronto date -d '2026-10-24 05:00' +%s) parsed"
same "a time with no date is the next one to come" \
  "$(rec "5-hour limit reached ∙ resets 11pm (UTC)")" "$(date -u -d '2026-10-23T23:00:00Z' +%s) parsed"
same "a time already past today is tomorrow's" \
  "$(rec "limit reached · resets 1:30am (UTC)")" "$(date -u -d '2026-10-24T01:30:00Z' +%s) parsed"
same "\"resets in 3h 20m\" is relative" "$(rec "Usage limit hit; resets in 3h 20m")" "$((NOW + 12000)) parsed"
same "the old \"usage limit reached|<epoch>\" form" \
  "$(rec "Claude AI usage limit reached|$((NOW + 7200))")" "$((NOW + 7200)) parsed"
same "the last limit message wins" \
  "$(rec $'old: resets 1am (UTC)\nnew: You\'ve hit your weekly limit · resets Oct 25, 9am (UTC)')" \
  "$(date -u -d '2026-10-25T09:00:00Z' +%s) parsed"
same "no reset in the message defaults to six hours" "$(rec "You've hit your weekly limit")" "$((NOW + 21600)) default"
same "--default-secs sets that default" "$(rec "API Error: 429" --default-secs 60)" "$((NOW + 60)) default"
same "a reset more than eight days out is not believed" \
  "$(rec "resets Dec 25, 5am (UTC)")" "$((NOW + 21600)) default"
python3 "$PF" limit-check --state "$FS" --provider claude --now "$NOW" >/dev/null
same "limit-check: limited before the reset" "$?" "0"
python3 "$PF" limit-check --state "$FS" --provider claude --now "$((NOW + 21601))" >/dev/null
same "limit-check: free after the reset" "$?" "1"
expect "  ... and the expired record is removed" [ ! -e "$FS/provider-limits/claude.json" ]
python3 "$PF" limit-check --state "$FS" --provider agy --now "$NOW" >/dev/null
same "limit-check: no record means no limit" "$?" "1"
expect "no temp files are left beside the record" [ -z "$(find "$FS" -name '.fallback.*')" ]

agyres() { # rc stdout-text [sha] -> verdict line
  printf '%s' "$2" > "$TMP/agy.out"; : > "$TMP/agy.err"
  python3 "$PF" agy-result --rc "$1" --stdout "$TMP/agy.out" --stderr "$TMP/agy.err" --sha "${3:-$SHA}" --report-out "$TMP/agy.report"
}
REPORT="## Automated review\n\n1. [blocking] x\n2. [suggestion] y\n\n<!-- pulse-review:v1 head=$SHA findings=2 -->"
same "agy-result: SUCCESS with this head's marker is ok" \
  "$(agyres 0 "{\"status\":\"SUCCESS\",\"response\":\"$REPORT\"}")" "$(printf 'ok\t2')"
expect "  ... and the report is Agy's response, marker last" eval \
  '[ "$(head -1 "$TMP/agy.report")" = "## Automated review" ] && [ "$(tail -1 "$TMP/agy.report")" = "<!-- pulse-review:v1 head=$SHA findings=2 -->" ]'
out="$(agyres 1 '{"status":"ERROR","error":"RESOURCE_EXHAUSTED: quota exceeded"}')"
expect "agy-result: an ERROR status quotes Agy's own error" has "$out" "RESOURCE_EXHAUSTED: quota exceeded"
out="$(agyres 0 "{\"status\":\"SUCCESS\",\"response\":\"$REPORT\"}" "$SHA2")"
expect "agy-result: a marker for another head is not this review" has "$out" "carries no review marker for $SHA2"
out="$(agyres 124 '')"
expect "agy-result: exit 124 is the worker timeout" has "$out" "worker timeout (exit 124)"
out="$(agyres 0 'not json at all')"
expect "agy-result: no JSON is a failure that quotes the output" has "$out" "without a JSON result: not json at all"

# ================================================================ whole ticks
echo
echo "pr-loop.sh fallback"
LC="$TMP/common"; mkdir -p "$LC/prompts"
for f in pr-loop.sh classify-pane.sh provider-fallback.py marker.py \
         prompts/review.txt prompts/resolve.txt prompts/review.agy.txt; do
  cp "$ROOT/$f" "$LC/$f"
done
DB="$TMP/db.json"; export DB
cat > "$LC/gitea-pr.py" <<'PY'
import json, os, sys
db = json.load(open(os.environ["DB"]))
cmd, a = sys.argv[1], dict(zip(sys.argv[2::2], sys.argv[3::2]))
pr = db["pr"]
if cmd == "list":
    print(json.dumps([pr]))
elif cmd == "head":
    print(pr["head_sha"])
elif cmd == "comments":
    print(json.dumps([{"id": i, "user": "bot", "created_at": "", "body": b} for i, b in enumerate(db["comments"])]))
elif cmd == "comment":
    db["comments"].append(open(a["--body-file"]).read())
elif cmd == "label":
    pr["labels"] = [l for l in pr["labels"] if l != a.get("--remove")] + [a["--add"]]
json.dump(db, open(os.environ["DB"], "w"))
PY

TMUXD="$TMP/tmux"; export TMUXD
cat > "$BIN/tmux" <<'SH'
#!/usr/bin/env bash
cmd="$1"; shift
t=""; prev=""
for a in "$@"; do case "$prev" in -t|-s) t="$a" ;; esac; prev="$a"; done
echo "$cmd $*" >> "$TMUXD/calls"
case "$cmd" in
  new-session) : > "$TMUXD/sess-$t"; echo 0 > "$TMUXD/n-$t"; echo pre > "$TMUXD/phase-$t"; cp "${*: -1}" "$TMUXD/launch-$t" ;;
  has-session) [ -f "$TMUXD/sess-$t" ]; exit ;;
  kill-session) rm -f "$TMUXD/sess-$t" ;;
  paste-buffer) echo post > "$TMUXD/phase-$t" ;;
  capture-pane)
    [ -f "$TMUXD/sess-$t" ] || exit 1
    if [ "$(cat "$TMUXD/phase-$t")" = pre ]; then echo '❯ '; exit 0; fi
    n="$(cat "$TMUXD/n-$t")"; echo $((n + 1)) > "$TMUXD/n-$t"
    if [ "$n" -lt 2 ]; then echo '✻ Reviewing… (esc to interrupt)'; else cat "$TMUXD/scenario"; fi ;;
esac
exit 0
SH
cat > "$BIN/git" <<'SH'
#!/usr/bin/env bash
[ "$1" = -C ] && shift 2
case "$1 ${2:-}" in
  "worktree add") mkdir -p "${@: -2:1}" ;;
  "worktree remove") rm -rf "${@: -1}" ;;
  diff*) printf 'diff --git a/app.py b/app.py\n+print("changed")\n' ;;
  log*) echo 'abc1234 the change' ;;
esac
exit 0
SH
AGY_CALLS="$TMP/agy-calls"; export AGY_CALLS
cat > "$BIN/agy" <<'SH'
#!/usr/bin/env bash
{
  echo "CALL"
  echo "PWD=$PWD"
  echo "STDIN=$(readlink /proc/self/fd/0)"
  [ -f .pr-loop-context.md ] && echo "CONTEXT_DIFF_LINES=$(grep -c '^diff --git' .pr-loop-context.md)"
  prev=""
  for a in "$@"; do [ "$prev" = -p ] && echo "PROMPT_HEAD=$(grep -o 'head=[0-9a-f]\{40\}' <<<"$a" | head -1)" || echo "ARG $a"; prev="$a"; done
} >> "$AGY_CALLS"
sha=""; prev=""
for a in "$@"; do [ "$prev" = -p ] && sha="$(grep -o 'head=[0-9a-f]\{40\}' <<<"$a" | head -1 | cut -d= -f2)"; prev="$a"; done
case "${AGY_BEHAVE:-ok}" in
  ok)    printf '{"status":"SUCCESS","conversation_id":"c1","response":"## Automated review\\n\\n1. [blocking] x\\n2. [suggestion] y\\n\\n<!-- pulse-review:v1 head=%s findings=2 -->"}\n' "$sha" ;;
  clean) printf '{"status":"SUCCESS","response":"## Automated review\\n\\nNo findings.\\n\\n<!-- pulse-review:v1 head=%s findings=0 -->"}\n' "$sha" ;;
  limit) echo '{"status":"ERROR","error":"RESOURCE_EXHAUSTED: Agy quota exceeded for today"}'; exit 1 ;;
  nomarker) echo '{"status":"SUCCESS","response":"I could not finish the review."}' ;;
  hang) sleep 30 ;;
esac
SH
for t in claude tea agent; do printf '#!/bin/sh\necho "%s $*" >> "$HOME/ran"\nexit 0\n' "$t" > "$BIN/$t"; done
chmod +x "$BIN"/*
mkdir -p "$TMP/main/.git"
ST="$TMP/state"
LIMIT="$ST/provider-limits/claude.json"

reset() { # labels-json [comments-json] [head]
  python3 - "$DB" "$1" "${2:-[]}" "${3:-$SHA}" <<'PY'
import json, sys
json.dump({"pr": {"number": 7, "title": "t", "draft": False, "head_sha": sys.argv[4], "head_ref": "feature/x",
                  "base_ref": "develop", "author": "craig", "is_bot": False, "labels": json.loads(sys.argv[2]),
                  "url": ""}, "comments": json.loads(sys.argv[3])}, open(sys.argv[1], "w"))
PY
  rm -rf "$TMUXD" "$TMP/wt"; mkdir -p "$TMUXD"; : > "$TMUXD/calls"; : > "$AGY_CALLS"; rm -f "$HOME/ran"
}
scenario() { printf '%s\n' "$1" > "$TMUXD/scenario"; }
loop() { # mode [env...] -> $TMP/out.txt
  local mode="$1"; shift
  env "$@" PR_LOOP_STATE="$ST" PR_LOOP_MAIN="$TMP/main" PR_LOOP_WORKTREES="$TMP/wt" PR_LOOP_REPO=o/r \
    SKIP_BUSY_GUARD=1 MIN_FREE_GB=0 POLL=0.2 timeout 120 bash "$LC/pr-loop.sh" "$mode" > "$TMP/out.txt" 2>&1
}
labels() { python3 -c 'import json,os; print(",".join(json.load(open(os.environ["DB"]))["pr"]["labels"]))'; }
comments() { python3 -c 'import json,os; print("\n----\n".join(json.load(open(os.environ["DB"]))["comments"]))'; }
limit_until() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["until"])' "$LIMIT" 2>/dev/null; }
log_() { cat "$TMP/out.txt"; }

# --- the incident: Claude hits its weekly limit mid-review
rm -rf "$ST"
reset '["review:requested"]'
RESET_DAY="$(date -u -d '+1 day' '+%b %-d')"
WANT_UNTIL="$(date -u -d "$(date -u -d '+1 day' +%F) 05:00" +%s)"
scenario "$(printf '%s\n' "$MENU" | sed "s/Oct 24, 5am (America\/Toronto)/$RESET_DAY, 5am (UTC)/")"
start=$(date +%s); loop review; took=$(( $(date +%s) - start ))
expect "weekly limit: the review lands on review:findings" [ "$(labels)" = "review:findings" ]
expect "  ... from Agy's response, marker contract unchanged" has "$(comments)" "<!-- pulse-review:v1 head=$SHA findings=2 -->"
expect "  ... posted as the whole comment, heading first" [ "$(comments | head -1)" = "## Automated review" ]
expect "  ... with no generic no-marker failure" lacks "$(comments)" "no review comment carrying the marker"
expect "  ... and no needs-human" lacks "$(labels)" "needs-human"
expect "  ... the Claude session was killed" eval 'grep -q "^kill-session -t prloop-review-7" "$TMUXD/calls" && [ ! -e "$TMUXD/sess-prloop-review-7" ]'
expect "  ... promptly, not after WORKER_TIMEOUT" [ "$took" -lt 30 ]
expect "  ... nothing was typed into the limit menu" lacks "$(grep '^send-keys' "$TMUXD/calls")" "continue"
same "  ... the limit is recorded with the parsed reset" "$(limit_until)" "$WANT_UNTIL"
expect "  ... the log says why" eval 'has "$(log_)" "Claude hit a usage limit" && has "$(log_)" "falling back to agy"'
expect "  ... agy reviews in plan mode" has "$(tr '\n' ' ' < "$AGY_CALLS")" "ARG --mode ARG plan"
expect "  ... with JSON output and no print timeout of its own" has "$(tr '\n' ' ' < "$AGY_CALLS")" "ARG --output-format ARG json ARG --print-timeout ARG 0"
expect "  ... never with auto-approve" lacks "$(cat "$AGY_CALLS")" "dangerously-skip-permissions"
expect "  ... with stdin closed to menus" grep -qx 'STDIN=/dev/null' "$AGY_CALLS"
expect "  ... in the PR worktree" grep -qx "PWD=$TMP/wt/prloop-review-7" "$AGY_CALLS"
expect "  ... with the diff in its context file" grep -qx 'CONTEXT_DIFF_LINES=1' "$AGY_CALLS"
expect "  ... and the head in its prompt" grep -qx "PROMPT_HEAD=head=$SHA" "$AGY_CALLS"
expect "  ... the worktree is cleaned up" [ ! -e "$TMP/wt/prloop-review-7" ]
expect "the launch script outlives claude to show why it exited" grep -q 'PR_LOOP_WORKER_EXIT=' "$TMUXD/launch-prloop-review-7"
expect "  ... and does not exec claude" eval '! grep -q "^exec claude" "$TMUXD/launch-prloop-review-7"'

# --- a later tick, the limit standing
reset '["review:requested"]' '[]' "$SHA2"
loop review
expect "limit standing: no Claude session is started" eval '! grep -q "^new-session" "$TMUXD/calls"'
expect "  ... Agy reviews directly" eval '[ "$(labels)" = "review:findings" ] && has "$(comments)" "head=$SHA2 findings=2"'
expect "  ... and the log says until when" has "$(log_)" "Claude is limited until"
reset '["review:requested"]' '[]' "$SHA2"
loop review DRY_RUN=1
expect "  ... a dry run says it would use Agy" has "$(log_)" "DRY: would spawn agy for #7"

reset '["review:requested"]' '[]' "$SHA2"
loop review AGY_BEHAVE=clean
same "  ... a zero-finding Agy review is review:clean" "$(labels)" "review:clean"

# --- Agy fails: the PR says what Agy said
reset '["review:requested"]' '[]' "$SHA2"
loop review AGY_BEHAVE=limit
same "agy limited too: review:needs-human" "$(labels)" "review:needs-human"
expect "  ... the comment quotes Agy's own error" has "$(comments)" "RESOURCE_EXHAUSTED: Agy quota exceeded for today"
expect "  ... not the generic no-marker message" lacks "$(comments)" "no review comment carrying the marker"
expect "  ... and so does the log" has "$(log_)" "RESOURCE_EXHAUSTED"

reset '["review:requested"]' '[]' "$SHA2"
loop review AGY_BEHAVE=nomarker
expect "agy without a marker: needs-human quoting its response" eval \
  '[ "$(labels)" = "review:needs-human" ] && has "$(comments)" "I could not finish the review."'

reset '["review:requested"]' '[]' "$SHA2"
start=$(date +%s); loop review AGY_BEHAVE=hang WORKER_TIMEOUT=2; took=$(( $(date +%s) - start ))
expect "agy hangs: the worker timeout ends it" eval '[ "$(labels)" = "review:needs-human" ] && has "$(comments)" "worker timeout"'
expect "  ... without hanging the tick" [ "$took" -lt 20 ]

reset '["review:requested"]' '[]' "$SHA2"
loop review PR_LOOP_AGY_BIN="$TMP/nowhere/agy"
expect "no Agy: the PR is left at review:requested" eval '[ "$(labels)" = "review:requested" ] && has "$(log_)" "Agy fallback is unavailable"'
reset '["review:requested"]' '[]' "$SHA2"
loop review PR_LOOP_AGY_BIN=agent
expect "a bare 'agent' is refused and never run" eval '[ ! -e "$HOME/ran" ] && has "$(log_)" "refusing a bare"'

# --- resolve
REVIEWED="[\"## Automated review\\n\\n1. x\\n\\n<!-- pulse-review:v1 head=$SHA findings=1 -->\"]"
reset '["review:findings"]' "$REVIEWED"
loop resolve
expect "resolve, limit standing: not claimed, left at review:findings" eval \
  '[ "$(labels)" = "review:findings" ] && ! grep -q "^new-session" "$TMUXD/calls"'
expect "  ... saying resolve has no fallback" has "$(log_)" "resolve has no fallback"
expect "  ... and Agy is never asked to resolve" [ ! -s "$AGY_CALLS" ]

rm -f "$LIMIT"
reset '["review:findings"]' "$REVIEWED"
scenario "$(printf '  ⎿  API Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"Claude AI usage limit reached|%s"}}\n> ' "$(( $(date +%s) + 5400 ))")"
loop resolve
expect "resolve hits the limit: back to review:findings, not needs-human" [ "$(labels)" = "review:findings" ]
expect "  ... the comment quotes Claude's own error" has "$(comments)" "rate_limit_error"
expect "  ... the limit is recorded" eval '[ -n "$(limit_until)" ]'
expect "  ... and Agy is never asked to resolve" [ ! -s "$AGY_CALLS" ]

# --- an expired limit, and Claude's own error text on other failures
mkdir -p "$(dirname "$LIMIT")"
printf '{"provider":"claude","until":%s,"reason":"old"}\n' "$(( $(date +%s) - 10 ))" > "$LIMIT"
reset '["review:requested"]'
scenario $'  ⎿  API Error: 500 {"type":"error","error":{"type":"api_error","message":"Internal server error"}}\nPR_REVIEW_DONE\n> '
loop review
expect "expired limit: Claude runs again" grep -q '^new-session -d -s prloop-review-7' "$TMUXD/calls"
expect "  ... and the stale record is gone" [ ! -e "$LIMIT" ]
expect "no marker: needs-human" [ "$(labels)" = "review:needs-human" ]
expect "  ... quoting Claude's own error line" has "$(comments)" "API Error: 500"

reset '["review:requested"]'
scenario $'Error: something broke\n\nPR_LOOP_WORKER_EXIT=1'
loop review
expect "claude exits: needs-human with its last words" eval \
  '[ "$(labels)" = "review:needs-human" ] && has "$(comments)" "Claude exited before finishing" && has "$(comments)" "something broke"'

expect "the user's real HOME was never used" [ ! -e "$HOME/.claude.json" ]

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
