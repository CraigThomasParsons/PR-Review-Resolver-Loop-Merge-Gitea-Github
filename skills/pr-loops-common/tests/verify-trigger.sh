#!/usr/bin/env bash
# Offline cases for the event trigger: pr-trigger's contract (arguments, exit codes, event and
# label normalisation, coalescing), the PR_LOOP_PR and PR_LOOP_LOCK_WAIT knobs in pr-loop.sh, and
# pr-drain's queue handling. Everything runs under a temporary HOME with the adapter, marker.py,
# claude, tea, tmux, git and php stubbed. No network, no repository, no systemd.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
BG=()
trap 'for p in "${BG[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
unset PR_LOOP_PINNED PR_LOOP_PR PR_LOOP_LOCK_WAIT PR_LOOP_STATE PR_PIPELINE_REPOS DRY_RUN

A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
C=cccccccccccccccccccccccccccccccccccccccc

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; [ $# -lt 2 ] || printf '         %s\n' "${@:2}"; }
expect() { # name condition-command...
  local name="$1"; shift
  if "$@"; then ok "$name"; else no "$name" "condition failed: $*"; fi
}
has() { [[ "$1" == *"$2"* ]]; }
lacks() { [[ "$1" != *"$2"* ]]; }
count_files() { find "$1" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l; }

hold_lock() { # file seconds -> waits until the lock is really held
  flock "$1" sleep "$2" & BG+=($!)
  local i
  for i in $(seq 1 50); do flock -n "$1" true 2>/dev/null || return 0; sleep 0.1; done
  echo "could not observe the lock on $1" >&2
}

# ================================================================ pr-trigger
echo "pr-trigger contract"
TS="$TMP/tstate"
trig() { PR_LOOP_STATE="$TS" bash "$ROOT/pr-trigger.sh" "$@"; }
rc_of() { "$@" >/dev/null 2>&1; echo $?; }

expect "repo without an owner exits 2"   [ "$(rc_of trig --repo noslash --pr 1 --sha $A)" = 2 ]
expect "repo with two slashes exits 2"   [ "$(rc_of trig --repo a/b/c --pr 1 --sha $A)" = 2 ]
expect "repo of .. exits 2"              [ "$(rc_of trig --repo a/.. --pr 1 --sha $A)" = 2 ]
expect "pr 0 exits 2"                    [ "$(rc_of trig --repo a/b --pr 0 --sha $A)" = 2 ]
expect "pr abc exits 2"                  [ "$(rc_of trig --repo a/b --pr abc --sha $A)" = 2 ]
expect "short sha exits 2"               [ "$(rc_of trig --repo a/b --pr 1 --sha abc123)" = 2 ]
expect "non-hex sha exits 2"             [ "$(rc_of trig --repo a/b --pr 1 --sha "${A%a}z")" = 2 ]
expect "missing --sha exits 2"           [ "$(rc_of trig --repo a/b --pr 1)" = 2 ]
expect "unknown argument exits 2"        [ "$(rc_of trig --repo a/b --pr 1 --sha $A --bogus x)" = 2 ]
expect "option without a value exits 2"  [ "$(rc_of trig --repo a/b --pr 1 --sha)" = 2 ]
expect "rejections are logged"           grep -q 'rejected (exit 2)' "$TS/trigger.log"
expect "no queue file after rejections"  [ "$(count_files "$TS/queue")" = 0 ]

touch "$TMP/not-a-dir"
expect "state path that is a file exits 3" \
  [ "$(PR_LOOP_STATE="$TMP/not-a-dir" bash "$ROOT/pr-trigger.sh" --repo a/b --pr 1 --sha $A >/dev/null 2>&1; echo $?)" = 3 ]
expect "no HOME and no PR_LOOP_STATE exits 3" \
  [ "$(env -u HOME -u PR_LOOP_STATE bash "$ROOT/pr-trigger.sh" --repo a/b --pr 1 --sha $A >/dev/null 2>&1; echo $?)" = 3 ]
mkdir -p "$TMP/ro"; chmod 500 "$TMP/ro"
if [ ! -w "$TMP/ro" ]; then
  expect "unwritable state directory exits 3" \
    [ "$(PR_LOOP_STATE="$TMP/ro/state" bash "$ROOT/pr-trigger.sh" --repo a/b --pr 1 --sha $A >/dev/null 2>&1; echo $?)" = 3 ]
fi
chmod 700 "$TMP/ro"

out="$(trig --repo a/b --pr 1 --sha $A --event closed --label "")"; rc=$?
expect "closed is ignored with exit 0"   [ "$rc" = 0 ]
expect "ignored event says why"          has "$out" "ignored: event closed"
out="$(trig --repo a/b --pr 1 --sha $A --event labeled --label foo)"; rc=$?
expect "label foo is ignored with exit 0" [ "$rc" = 0 ]
expect "ignored label says why"          has "$out" "ignored: label foo"
out="$(trig --repo a/b --pr 1 --sha $A --event label_updated --label review:clean)"
expect "review:clean does not fire"      has "$out" "ignored: label review:clean"
expect "ignored events write no file"    [ "$(count_files "$TS/queue")" = 0 ]

q="$TS/queue/a__b__1.json"
out="$(trig --repo a/b --pr 1 --sha $A --event opened --label "")"; rc=$?
expect "opened with an empty --label queues" eval '[ "$rc" = 0 ] && [ -f "$q" ]'
expect "opened says queued"              has "$out" "queued: a/b#1 $A event=opened"
expect "opened needs the label stage"    grep -q '"label_stage": true' "$q"
rm -f "$q"

out="$(trig --repo a/b --pr 1 --sha $A --event synchronized --label "")"
expect "Gitea's synchronized is accepted" grep -q '"event": "synchronize"' "$q"
expect "raw spelling is kept"            grep -q '"raw_event": "synchronized"' "$q"
rm -f "$q"

out="$(trig --repo a/b --pr 1 --sha $A --event label_updated --label "")"
expect "label_updated with an empty label queues as unknown" has "$out" "event=labeled label=unknown"
expect "a bare label event has no label stage" grep -q '"label_stage": false' "$q"
rm -f "$q"

out="$(trig --repo a/b --pr 1 --sha $A --event labeled --label review:findings)"
expect "labeled review:findings queues"  has "$out" "label=review:findings"
rm -f "$q"

out="$(trig --repo a/b --pr 1 --sha $A)"
expect "no --event means manual"         grep -q '"event": "manual"' "$q"
rm -f "$q"

out="$(trig --repo a/b --pr 1 --sha "${A^^}" --event opened)"
expect "an upper-case sha is normalised" grep -q "\"sha\": \"$A\"" "$q"
rm -f "$q"

trig --repo a/b --pr 1 --sha $A --event opened >/dev/null
trig --repo a/b --pr 1 --sha $B --event synchronized >/dev/null
expect "repeat events coalesce to one file" [ "$(count_files "$TS/queue")" = 1 ]
expect "the newest sha wins"             grep -q "\"sha\": \"$B\"" "$q"
trig --repo a/b --pr 1 --sha $B --event labeled --label review:requested >/dev/null
expect "a label event on top keeps the pending label stage" grep -q '"label_stage": true' "$q"
expect "and records the newer event"     grep -q '"event": "labeled"' "$q"
mkdir -p "$TS/processing"; mv "$q" "$TS/processing/"
trig --repo a/b --pr 1 --sha $C --event synchronized >/dev/null
expect "an event during processing gets a new queue file" grep -q "\"sha\": \"$C\"" "$q"
expect "and leaves the processing file alone" grep -q "\"sha\": \"$B\"" "$TS/processing/a__b__1.json"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$q" 2>/dev/null
expect "the queue file is valid JSON"    [ $? = 0 ]
expect "nothing is left in queue.tmp"    [ -z "$(find "$TS/queue.tmp" -type f ! -name .lock)" ]
expect "every call is logged"            grep -q "queued: a/b#1 sha=$C event=synchronized" "$TS/trigger.log"

# ================================================================ pr-loop.sh knobs
echo
echo "pr-loop.sh PR_LOOP_PR / PR_LOOP_LOCK_WAIT"
LC="$TMP/loopcommon"; mkdir -p "$LC/prompts"
cp "$ROOT/pr-loop.sh" "$LC/pr-loop.sh"
printf 'review __PR__\n' > "$LC/prompts/review.txt"; printf 'resolve __PR__\n' > "$LC/prompts/resolve.txt"
printf '#!/bin/sh\necho STATE=WORKING\n' > "$LC/classify-pane.sh"; chmod +x "$LC/classify-pane.sh"
cat > "$LC/gitea-pr.py" <<PY
import json, os, sys
if sys.argv[1] == "list":
    print(json.dumps([
      {"number": n, "title": "t", "draft": False, "head_sha": s, "head_ref": "feature/%d" % n,
       "base_ref": "develop", "author": "craig", "is_bot": False,
       "labels": ["review:requested"], "url": ""} for n, s in ((7, "$A"), (8, "$B"))]))
elif sys.argv[1] in ("label", "labels"):
    a = sys.argv[2:]
    arg = lambda n: a[a.index(n) + 1] if n in a else None
    path = os.environ["LABEL_STATE"]
    state = json.load(open(path)) if os.path.exists(path) else {}
    pr = arg("--pr")
    cur = set(state.get(pr, ["review:requested"]))
    if sys.argv[1] == "label":
        add = arg("--add")
        remove = arg("--remove")
        # Simulates the real failure: the Gitea API accepts an unknown label name as a no-op,
        # exit 0, nothing added -- ADAPTER_NO_AGENT_LABEL stands in for a repo the label
        # roller was never run against.
        if add and not (add == "agent:ready" and os.environ.get("ADAPTER_NO_AGENT_LABEL")):
            cur.add(add)
        if remove:
            cur.discard(remove)
        state[pr] = sorted(cur)
        json.dump(state, open(path, "w"))
    else:
        print(json.dumps(sorted(cur)))
PY
cat > "$LC/marker.py" <<'PY'
import os, sys
print(os.environ.get("MARKER_" + sys.argv[2], ""))
PY
for t in claude tea tmux git; do printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/$t"; chmod +x "$HOME/.local/bin/$t"; done
mkdir -p "$TMP/main/.git"
LS="$TMP/loopstate"
loop() { DRY_RUN=1 PR_LOOP_STATE="$LS" PR_LOOP_MAIN="$TMP/main" PR_LOOP_WORKTREES="$TMP/wt" \
  PR_LOOP_REPO=o/r bash "$LC/pr-loop.sh" review 2>&1; }

out="$(loop)"
expect "unset PR_LOOP_PR still takes every PR (timer unchanged)" has "$out" "would spawn prloop-review-7"
expect "  ... including #8"              has "$out" "would spawn prloop-review-8"
expect "the log prefix names the repo"   has "$out" "[review] [o/r]"
out="$(PR_LOOP_PR=8 loop)"
expect "PR_LOOP_PR=8 spawns #8"          has "$out" "would spawn prloop-review-8"
expect "PR_LOOP_PR=8 leaves #7 alone"    lacks "$out" "prloop-review-7"
out="$(PR_LOOP_PR=8 MARKER_8="$B 2" loop)"
expect "a head marker still means skip"  has "$out" "#8 head $B already reviewed (marker)"
out="$(PR_LOOP_PR=9 loop)"
expect "a PR without the label says so"  has "$out" "#9 is not an open, non-draft, non-bot PR carrying review:requested"
out="$(PR_LOOP_PR=x loop)"
expect "a bad PR_LOOP_PR is a setup fault" has "$out" "FATAL: PR_LOOP_PR must be a PR number"
out="$(PR_LOOP_LOCK_WAIT=soon loop)"
expect "a bad PR_LOOP_LOCK_WAIT is a setup fault" has "$out" "FATAL: PR_LOOP_LOCK_WAIT must be whole seconds"

mkdir -p "$LS"
hold_lock "$LS/review.lock" 3
out="$(PR_LOOP_PR=8 loop)"
expect "held lock, no wait: exits at once" has "$out" "previous review tick still running; exiting"
expect "  ... and spawns nothing"        lacks "$out" "would spawn"
out="$(PR_LOOP_PR=8 PR_LOOP_LOCK_WAIT=1 loop)"
expect "held lock, short wait: gives up" has "$out" "gave up waiting 1s for the review lock"
start=$(date +%s)
out="$(PR_LOOP_PR=8 PR_LOOP_LOCK_WAIT=20 loop)"
waited=$(( $(date +%s) - start ))
expect "held lock, long wait: waits, then proceeds" has "$out" "would spawn prloop-review-8"
expect "  ... after announcing the wait" has "$out" "waiting up to 20s"
expect "  ... and returned once the lock was free" [ "$waited" -lt 15 ]

# ---------------------------------------------------------- pool hand-off
echo
echo "pool hand-off (PR_LOOP_POOL=1, not dry-run)"
LABEL_STATE="$TMP/label-state.json"; export LABEL_STATE
loop_live() { PR_LOOP_STATE="$LS" PR_LOOP_MAIN="$TMP/main" PR_LOOP_WORKTREES="$TMP/wt" \
  PR_LOOP_REPO=o/r PR_LOOP_POOL=1 bash "$LC/pr-loop.sh" review 2>&1; }

rm -f "$LABEL_STATE"
out="$(PR_LOOP_PR=8 loop_live)"
expect "a working hand-off adds agent:ready" has "$out" "#8: handed off to the agent pool"
expect "  ... and removes review:requested, verified, not just assumed" \
  [ "$(python3 -c 'import json; print(json.load(open("'"$LABEL_STATE"'"))["8"])')" = "['agent:ready']" ]

rm -f "$LABEL_STATE"
out="$(ADAPTER_NO_AGENT_LABEL=1 PR_LOOP_PR=8 loop_live)"
expect "a repo missing the agent:ready label: hand-off is reported as failed, not silently ok" \
  has "$out" "warning: hand-off of #8 to the agent pool failed"
expect "  ... review:requested is never removed when the add did not land" \
  [ "$(python3 -c 'import json; print(json.load(open("'"$LABEL_STATE"'"))["8"])')" = "['review:requested']" ]
expect "  ... so the PR is never left with no label at all" \
  [ -n "$(python3 -c 'import json; print(json.load(open("'"$LABEL_STATE"'"))["8"])')" ]

# ================================================================ pr-drain
echo
echo "pr-drain"
DC="$TMP/draincommon"; mkdir -p "$DC"
CALLS="$TMP/calls"; export CALLS
cat > "$DC/pr-loop.sh" <<'SH'
#!/usr/bin/env bash
echo "$1 repo=$PR_LOOP_REPO main=$PR_LOOP_MAIN pr=$PR_LOOP_PR wait=$PR_LOOP_LOCK_WAIT dry=$DRY_RUN" >> "$CALLS"
SH
chmod +x "$DC/pr-loop.sh"
PRS="$TMP/prs.json"; export PRS
cat > "$DC/gitea-pr.py" <<'PY'
import os, sys
if os.environ.get("ADAPTER_FAIL"):
    sys.exit("gitea-pr: HTTP 500")
if sys.argv[1] == "list":
    print(open(os.environ["PRS"]).read())
PY
cat > "$HOME/.local/bin/php" <<'SH'
#!/usr/bin/env bash
if [ "$2" = help ]; then printf '%s\n' "${PHP_HELP:-}"; exit 0; fi
echo "php $*" >> "$CALLS"
SH
chmod +x "$HOME/.local/bin/php"
mkdir -p "$TMP/crew" "$HOME/Code/r/.git"
DS="$TMP/dstate"
prs() { # number draft labels-json
  printf '[{"number": %s, "title": "t", "draft": %s, "head_sha": "%s", "head_ref": "f", "base_ref": "develop", "author": "craig", "is_bot": false, "labels": %s, "url": ""}]\n' \
    "$1" "$2" "$B" "$3" > "$PRS"
}
qd() { PR_LOOP_STATE="$DS" bash "$ROOT/pr-trigger.sh" "$@" >/dev/null; }
drain() { : > "$CALLS"
  PR_LOOP_STATE="$DS" PR_LOOPS_COMMON="${DRAIN_COMMON:-$DC}" NIGHT_CREW_DIR="$TMP/crew" \
    PR_PIPELINE_REPOS="o/r,o/nocheckout" bash "$ROOT/pr-drain.sh" 2>&1; }
calls() { cat "$CALLS"; }
drained() { [ "$(count_files "$DS/queue")" = 0 ] && [ "$(count_files "$DS/processing")" = 0 ]; }

prs 8 false '["review:requested"]'
qd --repo o/r --pr 8 --sha $B --event opened --label ""
out="$(drain)"
expect "opened: full label sweep when label-prs has no --repo/--pr" grep -qx 'php artisan nightcrew:label-prs' "$CALLS"
expect "  ... then review with the PR, checkout and default wait" \
  grep -qx "review repo=o/r main=$HOME/Code/r pr=8 wait=3600 dry=0" "$CALLS"
expect "  ... then resolve"              grep -qx "resolve repo=o/r main=$HOME/Code/r pr=8 wait=3600 dry=0" "$CALLS"
expect "  ... in that order"             [ "$(cut -d' ' -f1 "$CALLS" | paste -sd, -)" = "php,review,resolve" ]
expect "  ... and the item is consumed"  drained

qd --repo o/r --pr 8 --sha $B --event synchronized
out="$(PHP_HELP='Options: --repo[=REPO] --pr[=PR] --dry-run' drain)"
expect "synchronize: scoped label-prs when supported" grep -qx 'php artisan nightcrew:label-prs --repo o/r --pr 8' "$CALLS"

qd --repo o/r --pr 8 --sha $B --event labeled --label review:requested
out="$(drain)"
expect "labeled: no label stage"         lacks "$(calls)" "php"
expect "labeled: review and resolve run" [ "$(cut -d' ' -f1 "$CALLS" | paste -sd, -)" = "review,resolve" ]

prs 8 false '["review:in-progress"]'
qd --repo o/r --pr 8 --sha $B --event label_updated --label ""
out="$(drain)"
expect "the loop's own relabel event is a cheap no-op" [ ! -s "$CALLS" ]
expect "  ... and says why"              has "$out" "carries neither review:requested nor review:findings"
expect "  ... and is consumed"           drained

prs 8 false '[]'
qd --repo o/r --pr 8 --sha $B --event opened
qd --repo o/r --pr 8 --sha $B --event labeled --label ""
out="$(drain)"
expect "a coalesced opened+labeled still runs the label stage" [ "$(cut -d' ' -f1 "$CALLS" | paste -sd, -)" = "php,review,resolve" ]

prs 8 false '["review:requested"]'
qd --repo o/other --pr 8 --sha $B --event opened
out="$(drain)"
expect "a repo outside the allowlist is dropped" eval '[ ! -s "$CALLS" ] && has "$out" "not in the PR pipeline allowlist"'
qd --repo o/nocheckout --pr 8 --sha $B --event opened
out="$(drain)"
expect "a repo with no checkout is dropped" eval '[ ! -s "$CALLS" ] && has "$out" "no local checkout"'
qd --repo o/r --pr 9 --sha $B --event opened
out="$(drain)"
expect "a closed PR is dropped"          eval '[ ! -s "$CALLS" ] && has "$out" "o/r#9: not open"'
prs 8 true '["review:requested"]'
qd --repo o/r --pr 8 --sha $B --event opened
out="$(drain)"
expect "a draft is dropped"              eval '[ ! -s "$CALLS" ] && has "$out" "draft; dropped"'
prs 8 false '["review:requested"]'
qd --repo o/r --pr 8 --sha $B --event opened
out="$(ADAPTER_FAIL=1 drain)"
expect "an unreadable PR is dropped, not retried" eval '[ ! -s "$CALLS" ] && drained'

qd --repo o/r --pr 8 --sha $B --event labeled --label review:findings
out="$(PR_TRIGGER_LOCK_WAIT=60 drain)"
expect "PR_TRIGGER_LOCK_WAIT reaches pr-loop.sh" grep -q 'review .* wait=60 ' "$CALLS"

qd --repo o/r --pr 8 --sha $B --event labeled --label review:requested
mv "$DS/queue/o__r__8.json" "$DS/processing/"
out="$(drain)"
expect "a leftover in processing/ is requeued and run" eval 'has "$out" "requeued" && [ "$(grep -c "^review" "$CALLS")" = 1 ]'
qd --repo o/r --pr 8 --sha $A --event labeled --label review:requested
mv "$DS/queue/o__r__8.json" "$DS/processing/"
qd --repo o/r --pr 8 --sha $B --event labeled --label review:requested
out="$(drain)"
expect "a leftover superseded by a newer event runs once" eval 'has "$out" "superseded" && [ "$(grep -c "^review" "$CALLS")" = 1 ]'
expect "  ... with the newer sha"        has "$out" "sha=$B"

qd --repo o/r --pr 8 --sha $B --event labeled --label review:requested
hold_lock "$DS/drain.lock" 2
out="$(drain)"
expect "another drain holding the lock: exit and leave the queue" \
  eval 'has "$out" "another drain holds the lock" && [ "$(count_files "$DS/queue")" = 1 ]'
sleep 2.2
out="$(drain)"
expect "  ... which the next drain picks up" eval '[ "$(grep -c "^review" "$CALLS")" = 1 ] && drained'

qd --repo o/r --pr 8 --sha $B --event opened
out="$(DRAIN_COMMON="$TMP/nowhere" drain)"; rc=$?
expect "a missing engine is a setup fault (exit 2)" eval '[ "$rc" = 2 ] && has "$out" "FATAL"'
expect "  ... and the queue is still consumed" drained

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
