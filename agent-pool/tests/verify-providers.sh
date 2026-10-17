#!/usr/bin/env bash
# Offline end-to-end cases for the agent pool tick (agent-pool/bin/prod-common.sh).
#
# Everything is stubbed: HOME is a temp directory whose .local/bin holds stub claude,
# cursor-agent, grok, agy and codex CLIs (also first on PATH), the Gitea adapter is a stub that
# keeps PR labels and comments in a JSON file and reads each PR's head from a local bare "origin"
# repo, so a controller push is visible to it. No real provider CLI, no network, no real state.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
POOL="$ROOT/agent-pool/bin/prod-common.sh"
REAL_COMMON="$ROOT/skills/pr-loops-common"
CLAIMREC="$ROOT/agent-pool/scripts/claim-record.py"
TMP="$(mktemp -d)"; trap 'pkill -f "sleep 30[01]" 2>/dev/null; rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
BIN="$HOME/.local/bin"
mkdir -p "$BIN" "$TMP/common" "$TMP/calls" "$TMP/behave"
export PATH="$BIN:$PATH"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
R=owner/repo
ORIGIN="$TMP/origin.git"
ODD_REF='feature/a|b&c'

# ---------------------------------------------------------------- a local "remote"
git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$TMP/main" 2>/dev/null
git -C "$TMP/main" commit -q --allow-empty -m base
git -C "$TMP/main" push -q origin HEAD:master
git -C "$TMP/main" checkout -q -b feature/x
echo change > "$TMP/main/f.txt"
git -C "$TMP/main" add f.txt
git -C "$TMP/main" commit -q -m change
git -C "$TMP/main" push -q origin feature/x
git -C "$TMP/main" push -q origin "HEAD:refs/heads/$ODD_REF"
SHA="$(git -C "$TMP/main" rev-parse HEAD)"
git -C "$TMP/main" checkout -q --detach

# ---------------------------------------------------------------- stub Gitea adapter
cat > "$TMP/common/gitea-pr.py" <<'PY'
import json, os, subprocess, sys
path = os.environ["STUB_GITEA"]
st = json.load(open(path))
a = sys.argv[1:]
arg = lambda n: a[a.index(n) + 1] if n in a else None
def save():
    json.dump(st, open(path, "w"), indent=1)
def wlog(msg):
    open(path + ".writes", "a").write(msg + "\n")
def head(p):
    out = subprocess.run(["git", "--git-dir", os.environ["STUB_ORIGIN"], "rev-parse", "--verify", "-q",
                          "refs/heads/" + p["head_ref"]], capture_output=True, text=True).stdout.strip()
    return out or p.get("head_sha", "")
cmd = a[0]
if cmd == "list":
    print(json.dumps([{"number": int(n), "title": "t", "draft": False, "head_sha": head(p),
                       "head_ref": p["head_ref"], "base_ref": "master", "author": "human",
                       "is_bot": False, "labels": p["labels"], "assignees": p.get("assignees", []),
                       "url": ""} for n, p in st["prs"].items()]))
elif cmd == "labels":
    print(json.dumps(st["prs"][arg("--pr")]["labels"]))
elif cmd == "label":
    p = st["prs"][arg("--pr")]
    remove = [x for x in (arg("--remove") or "").split(",") if x]
    p["labels"] = [l for l in p["labels"] if l not in remove]
    for x in (arg("--add") or "").split(","):
        if x and x not in p["labels"]:
            p["labels"].append(x)
    save(); wlog(f"label {arg('--pr')} -{arg('--remove')} +{arg('--add')}")
elif cmd == "comment":
    st["prs"][arg("--pr")]["comments"].append({"id": 1, "user": "bot", "created_at": "",
                                               "body": open(arg("--body-file")).read()})
    save(); wlog(f"comment {arg('--pr')}")
elif cmd == "comments":
    print(json.dumps(st["prs"][arg("--pr")]["comments"]))
elif cmd == "head":
    print(head(st["prs"][arg("--pr")]))
else:
    sys.exit(f"stub adapter: unexpected {cmd}")
PY
cp "$REAL_COMMON/marker.py" "$TMP/common/marker.py"
export STUB_GITEA="$TMP/gitea.json" STUB_ADAPTER="$TMP/common/gitea-pr.py" STUB_REPO="$R" STUB_PR=7
export STUB_CALLS="$TMP/calls" STUB_BEHAVE="$TMP/behave" STUB_CLAIMREC="$CLAIMREC" STUB_ORIGIN="$ORIGIN"

# ---------------------------------------------------------------- stub provider CLIs
cat > "$BIN/stub-provider" <<'SH'
#!/usr/bin/env bash
name="$(basename "$0")"
stdin="$(cat)"
prompt="$stdin"; prev=""
for a in "$@"; do
  [ "$prev" = --prompt-file ] && prompt="$(cat "$a")"
  [ "$prev" = -p ] && [ "$name" = agy ] && prompt="$a"
  prev="$a"
done
[ "$name" = cursor-agent ] && prompt="${*: -1}"
report="$(printf '%s\n' "$prompt" | sed -n 's/.*Write the report to \([^ ]*\) (that exact path.*/\1/p' | head -1)"
review_head="$(printf '%s\n' "$prompt" | sed -n 's/.*That review was of head \([0-9a-f]*\) .*/\1/p' | head -1)"
findings="$(printf '%s\n' "$prompt" | sed -n 's/.* and raised \([0-9]*\) finding.*/\1/p' | head -1)"
claim_provider="$(python3 "$STUB_CLAIMREC" show --repo "$STUB_REPO" --pr "$STUB_PR" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("provider",""))')"
{
  echo "--- call"
  printf 'ARG %s\n' "$@"
  echo "PWD=$PWD"
  echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY-unset}"
  echo "PARENT=$(ps -o args= -p "$PPID" 2>/dev/null)"
  echo "SID=$(ps -o sid= -p $$ | tr -d ' ')"
  echo "CLAIM_PROVIDER=$claim_provider"
  echo "REPORT=$report"
  [ -f "$PWD/.cursor/cli.json" ] && echo "CURSOR_CLI_JSON=present"
} >> "$STUB_CALLS/$name.log"
behave="$(cat "$STUB_BEHAVE/$name" 2>/dev/null || echo ok)"
here() { git rev-parse HEAD; }
review_text() { printf '## Automated review\n1. [suggestion] something\n<!-- pulse-review:v1 head=%s findings=%s -->\n' "$(here)" "$1"; }
resolve_text() { printf '## Automated resolve\nFixed: see commits\n<!-- pulse-resolve:v1 head=%s reviewed=%s fixed=%s noted=%s deferred=%s -->\n' \
  "$(here)" "$review_head" "$1" "$2" "$3"; }
success() { # [final text]
  python3 - "$name" "${1:-done}" <<'PY'
import json, sys
name, text = sys.argv[1], sys.argv[2]
if name == "claude":
    print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": text, "session_id": "sess-claude", "permission_denials": []}))
elif name == "cursor-agent":
    print(json.dumps({"type": "system", "subtype": "init"}))
    print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": text}))
elif name == "grok":
    print(json.dumps({"text": text, "stopReason": "EndTurn"}))
elif name == "agy":
    print(json.dumps({"status": "SUCCESS", "conversation_id": "conv-agy-1", "response": text}))
else:
    print(text)
PY
}
commit_fix() { echo "fix $RANDOM" >> f.txt; git add f.txt; git commit -q -m "fix: something"; }
case "$behave" in
  ok)        review_text 2 > "$report"; success ;;
  clean)     review_text 0 > "$report"; success ;;
  final-only) success "$(review_text 2)" ;;
  silent)    success ;;
  hang)      sleep 60; success ;;
  resolve-noted)    resolve_text 0 1 0 > "$report"; success ;;
  resolve-deferred) resolve_text 0 0 1 > "$report"; success ;;
  resolve-fix)      commit_fix; resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"; success ;;
  resolve-miscount) commit_fix; resolve_text 1 "${findings:-1}" 0 > "$report"; success ;;
  resolve-unclaimed) commit_fix; resolve_text 0 "${findings:-1}" 0 > "$report"; success ;;
  resolve-push)
    commit_fix
    git push -q origin HEAD:refs/heads/feature/x >/dev/null 2>&1
    echo "PUSH_RC=$?" >> "$STUB_CALLS/$name.log"
    resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"; success ;;
  resolve-nonff)
    git checkout -q --detach HEAD~1; commit_fix; resolve_text 1 0 0 > "$report"; success ;;
  resolve-race)
    commit_fix
    ( unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
      c="$(mktemp -d)"; git clone -q "$STUB_ORIGIN" "$c" 2>/dev/null; cd "$c" && git checkout -q feature/x \
        && echo human >> h.txt && git add h.txt && git commit -q -m human && git push -q "$STUB_ORIGIN" HEAD:refs/heads/feature/x )
    resolve_text 1 0 0 > "$report"; success ;;
  steal|steal-quick)
    review_text 2 > "$report"
    # Another worker finds this claim stale (its clock is far ahead), requeues and re-claims it.
    attempt="$(python3 "$STUB_CLAIMREC" show --repo "$STUB_REPO" --pr "$STUB_PR" | python3 -c 'import json,sys; print(json.load(sys.stdin)["attempt_id"])')"
    AGENT_POOL_NOW=$(( $(date +%s) + 100000 )) python3 "$STUB_CLAIMREC" requeue --repo "$STUB_REPO" --pr "$STUB_PR" \
      --attempt "$attempt" --adapter "$STUB_ADAPTER" >/dev/null
    python3 "$STUB_CLAIMREC" claim --repo "$STUB_REPO" --pr "$STUB_PR" --worker thief --provider grok \
      -- python3 "$STUB_ADAPTER" label --repo "$STUB_REPO" --pr "$STUB_PR" --remove agent:ready --add agent:claimed \
      > "$STUB_CALLS/thief-attempt"
    sleep 301 >/dev/null 2>&1 &
    echo $! > "$STUB_CALLS/grandchild.pid"
    [ "$behave" = steal ] && sleep 300
    success ;;
  limit)
    case "$name" in
      claude) echo '{"type":"result","subtype":"success","is_error":true,"result":"Credit balance is too low"}' ;;
      cursor-agent) echo '{"type":"system","subtype":"init"}'; echo 'Error: rate limit exceeded' >&2; exit 1 ;;
      grok) echo 'HTTP 429 Too Many Requests' >&2; exit 1 ;;
      agy) echo '{"status":"ERROR","error":"RESOURCE_EXHAUSTED"}'; exit 1 ;;
      codex) echo 'insufficient credits' >&2; exit 1 ;;
    esac ;;
  login)
    echo '{"type":"result","subtype":"success","is_error":true,"result":"Invalid API key · Please run /login"}'; exit 1 ;;
  denied)
    case "$name" in
      cursor-agent)
        echo '{"type":"tool_call","subtype":"completed","tool_call":{"shellToolCall":{"args":{"command":"git commit -m x"},"result":{"permissionDenied":{"reason":"deny rule"}}}}}'
        echo '{"type":"result","subtype":"success","is_error":false,"result":"could not commit"}' ;;
      agy) echo '{"status":"SUCCESS","denied_actions":[{"tool":"run_command","command":"python3"}]}' ;;
      claude) echo '{"type":"result","subtype":"success","is_error":false,"result":"x","permission_denials":[{"tool_name":"Bash"}]}' ;;
    esac ;;
esac
exit 0
SH
chmod +x "$BIN/stub-provider"
for cli in claude cursor-agent grok agy codex; do ln -s stub-provider "$BIN/$cli"; done

# ---------------------------------------------------------------- harness
export AGENT_POOL_MAIN="$TMP/main" AGENT_POOL_REPO="$R" AGENT_POOL_STATE="$TMP/state"
export AGENT_POOL_WORKTREES="$TMP/wt" AGENT_POOL_ADAPTER="$TMP/common/gitea-pr.py"
export AGENT_POOL_MARKER="$TMP/common/marker.py" AGENT_POOL_WORKER_ID=test-worker AGENT_POOL_WATCH_SECS=1
export ANTHROPIC_API_KEY=stale-key-for-test PR_LOOP_SKIP_PATTERN=""
unset PROVIDER_ORDER AGY_AUTO_APPROVE

reset() { # labels-json [assignees-json] [comments-json] [head-ref]
  rm -rf "$TMP/state" "$TMP/calls"/* "$TMP/behave"/* "$STUB_GITEA.writes"
  git --git-dir "$ORIGIN" update-ref refs/heads/feature/x "$SHA"
  git --git-dir "$ORIGIN" update-ref "refs/heads/$ODD_REF" "$SHA"
  python3 - "$STUB_GITEA" "$1" "${2:-[]}" "${3:-[]}" "${4:-feature/x}" "$SHA" <<'PY'
import json, sys
path, labels, assignees, comments, ref, sha = sys.argv[1:]
json.dump({"prs": {"7": {"head_ref": ref, "head_sha": sha, "labels": json.loads(labels),
                         "assignees": json.loads(assignees), "comments": json.loads(comments)}}}, open(path, "w"))
PY
}
behave() { echo "$2" > "$TMP/behave/$1"; }
tick() { bash "$POOL" > "$TMP/out.txt" 2>&1; TICK_RC=$?; }
labels() { python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1]))["prs"]["7"]["labels"]))' "$STUB_GITEA"; }
comments() { python3 "$STUB_ADAPTER" comments --repo $R --pr 7; }
calls() { cat "$TMP/calls/$1.log" 2>/dev/null; }
ncalls() { grep -c -- '--- call' "$TMP/calls/$1.log" 2>/dev/null || echo 0; }
cooldown_doc() { cat "$TMP/state/cooldowns/$1.json" 2>/dev/null || echo none; }
origin_head() { git --git-dir "$ORIGIN" rev-parse "refs/heads/${1:-feature/x}"; }
record() { python3 "$CLAIMREC" show --repo $R --pr 7; }
writes() { cat "$STUB_GITEA.writes" 2>/dev/null; }
REVIEW_MARKER="[{\"id\":1,\"user\":\"bot\",\"created_at\":\"\",\"body\":\"## Automated review\\n1. x\\n<!-- pulse-review:v1 head=$SHA findings=1 -->\"}]"
CLEAN_MARKER="[{\"id\":1,\"user\":\"bot\",\"created_at\":\"\",\"body\":\"<!-- pulse-review:v1 head=$SHA findings=0 -->\"}]"

pass=0; fail=0
expect() { # name got wanted-substring
  if [[ "$2" == *"$3"* ]]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n         wanted *%s*\n         got %s\n' "$1" "$3" "$2"
    sed 's/^/           | /' "$TMP/out.txt" | tail -15; fi
}
expect_not() { # name got unwanted-substring
  if [[ "$2" != *"$3"* ]]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n         did not want *%s*\n         got %s\n' "$1" "$3" "$2"
    sed 's/^/           | /' "$TMP/out.txt" | tail -15; fi
}

# ---------------------------------------------------------------- cases
echo "provider limit: cooldown, back to agent:ready"
reset '["agent:ready"]'
behave claude limit
tick
expect "the PR goes back to agent:ready" "$(labels)" "agent:ready"
expect_not "never a silent agent:needs-human" "$(labels)" "agent:needs-human"
expect "claude gets a 1h cooldown file" "$(cooldown_doc claude)" '"seconds": 3600'
expect "the limit is logged as a limit" "$(cat "$TMP/out.txt")" "LIMIT [claude]"
expect "claude runs with ANTHROPIC_API_KEY unset" "$(calls claude)" "ANTHROPIC_API_KEY=unset"
expect "claude adapter shape" "$(calls claude | tr '\n' ' ')" "ARG -p ARG --output-format ARG json ARG --model ARG opus ARG --permission-mode ARG default"
expect "claude may read through the adapter's absolute path" "$(calls claude)" "ARG Bash(python3 $TMP/common/gitea-pr.py head *)"
expect_not "claude gets no python3 * allow" "$(calls claude)" "ARG Bash(python3 *)"
expect "claude is denied every push" "$(calls claude)" "ARG Bash(git push*)"
expect "claude may write its report in the runs dir" "$(calls claude | tr '\n' ' ')" "ARG --add-dir ARG $TMP/state/runs"
expect "claude runs the policy's PreToolUse hook" "$(calls claude)" '"PreToolUse"'
expect "claude review writes are scoped to the report" "$(calls claude)" "ARG Write(/$TMP/state/runs/report-7-"
expect_not "claude review gets no bare Write" "$(calls claude)" $'ARG Write\n'
expect "PROVIDER_ORDER unset means claude only; codex is never in the default" "$(ncalls cursor-agent)$(ncalls grok)$(ncalls agy)$(ncalls codex)" "0000"
expect "the tick itself is a normal exit" "$TICK_RC" "0"
worker_sid="$(calls claude | sed -n 's/^SID=//p' | head -1)"
expect "the worker runs in its own session (setsid), not the tick's" \
  "$([ -n "$worker_sid" ] && [ "$worker_sid" != "$(ps -o sid= -p $$ | tr -d ' ')" ] && echo own || echo "shared ($worker_sid)")" "own"

echo
echo "fallback: the next provider, recorded in the claim"
reset '["agent:ready"]'
behave claude limit; behave cursor-agent ok
PROVIDER_ORDER=claude,cursor tick
expect "cursor finished the review claude could not" "$(comments)" "pulse-review:v1 head=$SHA findings=2"
expect "a review with findings goes back to agent:ready, queued for resolve" "$(labels)" "agent:ready"
expect "the claim named cursor while cursor ran" "$(calls cursor-agent)" "CLAIM_PROVIDER=cursor"
expect "and claude while claude ran" "$(calls claude)" "CLAIM_PROVIDER=claude"
expect "the fallback is logged" "$(cat "$TMP/out.txt")" "falling back to cursor"
expect "claude cooled down" "$(cooldown_doc claude)" '"strikes": 1'
expect "cursor adapter shape" "$(calls cursor-agent | tr '\n' ' ')" "ARG -p ARG --trust ARG --workspace ARG $TMP/wt/"
expect_not "cursor runs without --force" "$(calls cursor-agent)" "ARG --force"
expect "cursor always gets --model" "$(calls cursor-agent | tr '\n' ' ')" "ARG --output-format ARG stream-json ARG --model ARG auto"
expect "cursor saw its per-worktree cli.json" "$(calls cursor-agent)" "CURSOR_CLI_JSON=present"
expect "the worktree config is excluded from commits" "$(cat "$TMP/main/.git/info/exclude")" "/.cursor/cli.json"
expect "the main clone stays clean" "$([ -z "$(git -C "$TMP/main" status --porcelain)" ] && echo clean || echo dirty)" "clean"
expect "no claim record is left behind" "$(record)" "{}"
reset '["agent:ready"]'
mkdir -p "$TMP/state/cooldowns"
behave cursor-agent ok
AGENT_POOL_NOW=$(date +%s) python3 "$ROOT/agent-pool/scripts/cooldown.py" record --provider claude --reason test >/dev/null
PROVIDER_ORDER=claude,cursor tick
expect "a cooling provider is skipped on the next tick" "$(ncalls claude)" "0"
expect "and the next provider is picked first" "$(comments)" "pulse-review:v1"

echo
echo "controller publication: workers write a report, the controller posts and pushes"
reset '["agent:ready"]'
behave claude ok
tick
expect "the worker was told where to write its report" "$(calls claude)" "REPORT=$TMP/state/runs/report-7-"
expect "the controller posted the report" "$(comments)" "## Automated review"
expect "with the review marker for the head" "$(comments)" "pulse-review:v1 head=$SHA findings=2"
expect "the claim flip, the comment and the release are the only writes" "$(writes | tr '\n' ' ')" \
  "label 7 -agent:ready +agent:claimed comment 7 label 7 -agent:claimed +agent:ready"
expect "the session id is logged" "$(cat "$TMP/out.txt")" "session sess-claude"
behave claude resolve-push
tick
expect "the next tick derives a resolve job from the findings" "$(cat "$TMP/out.txt")" "for resolve"
expect "the resolve prompt carries the reviewed head" "$(cat "$TMP/state/runs/prompt-7-"*-claude.txt)" "That review was of head $SHA and raised 2"
expect "the worker's own push failed" "$(calls claude)" "PUSH_RC=1"
expect_not "the worker's push never reached the remote" "$(calls claude)" "PUSH_RC=0"
newhead="$(origin_head)"
expect_not "the controller pushed the worker's commit" "$newhead" "$SHA"
expect "as a fast-forward of the reviewed head" "$(git --git-dir "$ORIGIN" merge-base --is-ancestor "$SHA" "$newhead" && echo ff)" "ff"
expect "and posted the resolve report" "$(comments)" "pulse-resolve:v1 head=$newhead reviewed=$SHA fixed=1"
expect "a verified resolve is agent:done" "$(labels)" "agent:done"
expect "the push is logged" "$(cat "$TMP/out.txt")" "pushed $SHA..$newhead to feature/x"
reset '["agent:ready"]'
behave claude clean
tick
expect "a clean review is agent:done" "$(labels)" "agent:done"
reset '["agent:ready"]'
behave claude final-only
tick
expect "a worker that could only answer in its final text is still published" "$(comments)" "pulse-review:v1 head=$SHA findings=2"
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-nonff
tick
expect "a non-fast-forward resolve is never pushed" "$(origin_head)" "$SHA"
expect "it goes to agent:needs-human" "$(labels)" "agent:needs-human"
expect "with a comment saying why" "$(comments)" "not a fast-forward"
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-miscount
tick
expect "a resolve marker that miscounts the findings is refused before any push" "$(origin_head)" "$SHA"
expect "and goes to needs-human with the reason" "$(comments)" "accounts for 2"
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-unclaimed
tick
expect "commits under a marker that claims no fixes are never pushed" "$(origin_head)" "$SHA"
expect "and go to needs-human" "$(labels)" "agent:needs-human"
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-race
tick
expect "if the branch moved on the remote during the run, nothing is pushed over it" "$(git --git-dir "$ORIGIN" log -1 --format=%s feature/x)" "human"
expect "the job is requeued" "$(labels)" "agent:ready"
expect "and the reason logged" "$(cat "$TMP/out.txt")" "the branch moved during the run"
expect_not "no resolve report was posted" "$(comments)" "pulse-resolve"

echo
echo "push target safety"
for ref in main release '+feature/x' release/1.0 -f; do
  reset '["agent:ready"]' '[]' '[]' "$ref"
  tick
  expect "head branch '$ref' is never taken" "$(cat "$TMP/out.txt")" "is not one the pool will push to"
  expect "and no provider ran for '$ref'" "$(ncalls claude)" "0"
done
reset '["agent:ready"]' '[]' "$REVIEW_MARKER" "$ODD_REF"
behave claude resolve-fix
tick
expect "a branch name with | and & renders into the prompt intact" "$(cat "$TMP/state/runs/prompt-7-"*-claude.txt)" "(branch $ODD_REF, base master)"
expect "and the controller pushes to exactly that branch" "$(git --git-dir "$ORIGIN" log -1 --format=%s "refs/heads/$ODD_REF")" "fix: something"
expect "and the job is done" "$(labels)" "agent:done"

echo
echo "fencing: a superseded attempt publishes nothing and its process group dies"
reset '["agent:ready"]'
behave claude steal
t0=$(date +%s); tick; took=$(( $(date +%s) - t0 ))
expect "the watcher noticed the claim moved on" "$(cat "$TMP/out.txt")" "superseded"
expect "and stopped the worker long before it finished" "$([ "$took" -lt 60 ] && echo fast || echo "slow ${took}s")" "fast"
gc="$(cat "$TMP/calls/grandchild.pid" 2>/dev/null)"
expect "the worker's grandchild was killed with its group" "$(kill -0 "$gc" 2>/dev/null && echo alive || echo dead)" "dead"
expect "the report it wrote was never posted" "$(comments)" "[]"
expect "the new holder's claim stands" "$(record)" "\"worker_id\": \"thief\""
expect "with the new attempt" "$(record)" "$(cat "$TMP/calls/thief-attempt")"
expect "the label is still the new holder's" "$(labels)" "agent:claimed"
expect_not "the superseded run released nothing" "$(writes)" "+agent:done"
reset '["agent:ready"]'
behave claude steal-quick
tick
expect "a worker that exits after losing its claim publishes nothing" "$(comments)" "[]"
gc="$(cat "$TMP/calls/grandchild.pid" 2>/dev/null)"
expect "and a straggler it left running is killed with its group" "$(kill -0 "$gc" 2>/dev/null && echo alive || echo dead)" "dead"
expect "the new holder's claim stands" "$(record)" "\"worker_id\": \"thief\""

echo
echo "reconciliation of claims (issue #1's table)"
reset '["agent:claimed"]'
AGENT_POOL_NOW=$(( $(date +%s) - 10000 )) python3 "$CLAIMREC" claim --repo $R --pr 7 --worker dead-worker --provider grok --deadline-secs 100 >/dev/null
behave claude ok
tick
expect "a claim past its deadline is requeued" "$(cat "$TMP/out.txt")" "passed its deadline"
expect "its provider is cooled down" "$(cooldown_doc grok)" '"strikes": 1'
expect "and the job is picked up again in the same tick" "$(comments)" "pulse-review:v1 head=$SHA"
reset '["agent:claimed"]'
python3 "$CLAIMREC" claim --repo $R --pr 7 --worker live-worker --provider claude >/dev/null
tick
expect "a live claim is respected" "$(cat "$TMP/out.txt")" "claimed by a live attempt"
expect "and the provider never ran" "$(ncalls claude)" "0"
reset '["agent:claimed"]'
tick
expect "agent:claimed with no claim record goes to agent:needs-human" "$(labels)" "agent:needs-human"
reset '["agent:done"]'
python3 "$CLAIMREC" claim --repo $R --pr 7 --worker w --provider claude >/dev/null
tick
expect "a record whose PR is no longer claimed is dropped" "$(record)" "{}"
expect "and nothing ran" "$(ncalls claude)" "0"

echo
echo "holds"
reset '["agent:ready"]' '["craig"]'
tick
expect "a human assignee is a human hold" "$(cat "$TMP/out.txt")" "held by a human"
reset '["agent:ready","status: in-progress"]'
tick
expect "status: in-progress with no claim waits out the grace, not forever" "$(cat "$TMP/out.txt")" "not a human hold"
expect "nothing ran during the grace" "$(ncalls claude)" "0"
AGENT_POOL_ORPHAN_GRACE=0 tick
expect "after the grace the orphan hold is reclaimed" "$(comments)" "pulse-review:v1"
expect_not "and the dead status: in-progress label is cleared" "$(labels)" "status: in-progress"

echo
echo "pre-verify: already-done work is settled without a provider"
reset '["agent:ready"]' '[]' "$CLEAN_MARKER"
tick
expect "a PR whose head already has a clean review is agent:done" "$(labels)" "agent:done"
expect "without spawning a provider" "$(ncalls claude)" "0"

echo
echo "setup faults: no cooldown, reported clearly"
reset '["agent:ready"]'
behave cursor-agent denied
PROVIDER_ORDER=cursor tick
expect "cursor permissionDenied gets no cooldown" "$(cooldown_doc cursor)" "none"
expect "the fault is recorded" "$(cat "$TMP/state/faults/cursor.json" 2>/dev/null)" "permissionDenied"
expect "the log says SETUP FAULT" "$(cat "$TMP/out.txt")" "SETUP FAULT [cursor]"
expect "the PR goes back to agent:ready, not needs-human" "$(labels)" "agent:ready"
expect "the tick exits 2 for a setup fault" "$TICK_RC" "2"
reset '["agent:ready"]'
behave claude login
tick
expect "S4: a fast login failure is a setup fault, not the fast-fail limit" "$(cat "$TMP/out.txt")" "SETUP FAULT [claude]"
expect "S4: and claude gets no cooldown" "$(cooldown_doc claude)" "none"
expect "S4: the PR goes back to agent:ready" "$(labels)" "agent:ready"
reset '["agent:ready"]'
WORKER_TIMEOUT=2700 tick
expect "WORKER_TIMEOUT not shorter than the claim deadline is refused" "$(cat "$TMP/out.txt")" "must be shorter than AGENT_POOL_DEADLINE_SECS"

echo
echo "agy"
reset '["agent:ready"]'
behave agy denied
PROVIDER_ORDER=agy AGENT_POOL_MODEL_AGY=test-model tick
expect "agy denied_actions despite SUCCESS gets no cooldown" "$(cooldown_doc agy)" "none"
expect "agy denied_actions is reported" "$(cat "$TMP/out.txt")" "SETUP FAULT [agy]"
expect "agy runs in the worktree" "$(calls agy)" "PWD=$TMP/wt/"
expect "agy flags: print timeout 0 so WORKER_TIMEOUT is the only limit" "$(calls agy | tr '\n' ' ')" "ARG --output-format ARG json ARG --print-timeout ARG 0"
expect "agy reviews in plan mode" "$(calls agy | tr '\n' ' ')" "ARG --mode ARG plan ARG --model ARG test-model"
expect "agy runs directly under the worker timeout" "$(calls agy | grep PARENT=)" "timeout -k 30"
expect_not "with no inner 120s timeout" "$(calls agy | grep PARENT=)" "timeout 120"
expect_not "agy auto-approve is never used for review" "$(calls agy)" "dangerously-skip-permissions"
reset '["agent:ready"]'
behave agy final-only
PROVIDER_ORDER=agy tick
expect_not "agy without a model is not a setup fault" "$(cat "$TMP/out.txt")" "SETUP FAULT"
expect_not "and is given no --model" "$(calls agy)" "ARG --model"
expect "the controller posts agy's plan-mode response as the review" "$(comments)" "pulse-review:v1 head=$SHA findings=2"
expect "agy's conversation_id is logged" "$(cat "$TMP/out.txt")" "session conv-agy-1"
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave agy resolve-noted
PROVIDER_ORDER=agy tick
expect "agy takes no resolve job without AGY_AUTO_APPROVE" "$(cat "$TMP/out.txt")" "no eligible provider takes resolve jobs"
expect "so agy never ran" "$(ncalls agy)" "0"
AGY_AUTO_APPROVE=1 PROVIDER_ORDER=agy tick
expect "with AGY_AUTO_APPROVE agy resolves" "$(labels)" "agent:done"
expect "with --dangerously-skip-permissions" "$(calls agy)" "ARG --dangerously-skip-permissions"
expect_not "and not in plan mode" "$(calls agy | tr '\n' ' ')" "ARG --mode ARG plan"

echo
echo "a provider timeout requeues, never needs-human"
reset '["agent:ready"]'
behave claude hang
WORKER_TIMEOUT=2 AGENT_POOL_FAST_FAIL_SECS=0 tick
expect "the timeout is logged as a timeout" "$(cat "$TMP/out.txt")" "hit the worker timeout"
expect "the PR goes back to agent:ready" "$(labels)" "agent:ready"
expect_not "not needs-human" "$(labels)" "agent:needs-human"
expect "and no needs-human comment" "$(comments)" "[]"
expect "and no cooldown" "$(cooldown_doc claude)" "none"
reset '["agent:ready"]'
behave agy hang
WORKER_TIMEOUT=2 AGENT_POOL_FAST_FAIL_SECS=0 PROVIDER_ORDER=agy tick
expect "an agy timeout requeues too" "$(labels)" "agent:ready"
expect_not "an agy timeout is never needs-human" "$(labels)" "agent:needs-human"

echo
echo "real verification failures still go to needs-human"
reset '["agent:ready"]'
behave claude silent
AGENT_POOL_FAST_FAIL_SECS=0 tick
expect "a slow run with no report is needs-human" "$(labels)" "agent:needs-human"
expect "with a comment saying why" "$(comments)" "the worker left no report"
expect "and no cooldown" "$(cooldown_doc claude)" "none"
reset '["agent:ready"]'
behave claude silent
tick
expect "the same run under 90s is the credit-wall fingerprint: a limit" "$(cat "$TMP/out.txt")" "with no marker"
expect "so it goes back to agent:ready" "$(labels)" "agent:ready"
expect "and cools claude down" "$(cooldown_doc claude)" '"strikes": 1'
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-deferred
tick
expect "resolve: a blocking finding left for a person is needs-human" "$(labels)" "agent:needs-human"
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-noted
tick
expect "resolve: a fully accounted, non-blocking disposition is done" "$(labels)" "agent:done"
expect "and nothing was pushed" "$(origin_head)" "$SHA"

echo
echo "grok and codex adapters"
reset '["agent:ready"]'
behave grok ok
PROVIDER_ORDER=grok tick
expect "grok finished the job" "$(comments)" "pulse-review:v1"
expect "grok adapter shape" "$(calls grok | tr '\n' ' ')" "ARG --cwd ARG $TMP/wt/"
expect "grok prompt file and JSON" "$(calls grok | tr '\n' ' ')" "ARG --output-format ARG json ARG --permission-mode ARG dontAsk"
expect "grok may write only its report outside the worktree" "$(calls grok | tr '\n' ' ')" "ARG --allow ARG Write($TMP/state/runs/report-7-"
expect "grok deny rules" "$(calls grok | tr '\n' ' ')" "ARG --deny ARG Bash(git push --force*)"
expect "grok review cannot commit" "$(calls grok | tr '\n' ' ')" "ARG --deny ARG Bash(git commit*)"
expect "grok model last" "$(calls grok | tr '\n' ' ')" "ARG -m ARG grok-build"
reset '["agent:ready"]'
behave grok limit
PROVIDER_ORDER=grok tick
expect "grok 429 cools grok down" "$(cooldown_doc grok)" '"strikes": 1'
reset '["agent:ready"]'
behave codex final-only
PROVIDER_ORDER=codex AGENT_POOL_MODEL_CODEX=test-codex tick
expect "the codex slot works when asked for" "$(comments)" "pulse-review:v1"
expect "codex adapter shape" "$(calls codex | tr '\n' ' ')" "ARG exec ARG --ephemeral ARG --sandbox ARG workspace-write"

echo
echo "prompts"
expect "the generic resolve prompt names files to stage" "$(cat "$REAL_COMMON/prompts/resolve.generic.txt")" "git add path/to/first/file"
expect_not "the generic prompts use no Claude-only skill" "$(cat "$REAL_COMMON/prompts/review.generic.txt" "$REAL_COMMON/prompts/resolve.generic.txt")" "mattpocock-skills"
expect_not "no prompt tells a worker to post a comment" "$(cat "$REAL_COMMON/prompts/review.generic.txt" "$REAL_COMMON/prompts/resolve.generic.txt")" "__ADAPTER__ comment "
expect_not "no prompt tells a worker to push" "$(cat "$REAL_COMMON/prompts/review.generic.txt" "$REAL_COMMON/prompts/resolve.generic.txt")" "git push origin"
expect "a rendered prompt has no unfilled placeholder" "$(cat "$TMP/state/runs/prompt-7-"*-codex.txt | grep -c '__[A-Z_]*__')" "0"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
