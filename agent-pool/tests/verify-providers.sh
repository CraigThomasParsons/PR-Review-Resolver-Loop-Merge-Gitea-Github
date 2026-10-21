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
TMP="$(mktemp -d)"
# Kill only the stub sleeps this run recorded, and only while each pid still is one.
cleanup() {
  local pid
  while read -r pid; do
    [[ "$(ps -o args= -p "$pid" 2>/dev/null)" == "sleep "* ]] && kill "$pid" 2>/dev/null
  done < <(cat "$TMP/stub-pids" 2>/dev/null)
  while read -r pid; do
    [[ "$(ps -o args= -p "$pid" 2>/dev/null)" == *fake-nightcrew.py* ]] && kill "$pid" 2>/dev/null
  done < <(cat "$TMP/server-pids" 2>/dev/null)
  rm -rf "$TMP"
}
trap cleanup EXIT
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
git -C "$TMP/main" commit -q --allow-empty -m "fix: an earlier resolve"
RESOLVED="$(git -C "$TMP/main" rev-parse HEAD)"
git -C "$TMP/main" push -q origin HEAD:refs/heads/resolved-fixture
git -C "$TMP/main" checkout -q --detach "$SHA"

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
    if os.path.exists(path + ".faildone") and "agent:done" in (arg("--add") or ""):
        sys.exit("stub adapter: Gitea hiccup on the release")
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
    p = st["prs"][arg("--pr")]
    lag = int(open(path + ".lag").read()) if os.path.exists(path + ".lag") else 0
    if lag > 0:
        # Gitea has not caught up with a push yet: the PR still shows its old head.
        open(path + ".lag", "w").write(str(lag - 1))
        print(p["head_sha"])
    else:
        print(head(p))
elif cmd == "state":
    p = st["prs"][arg("--pr")]
    if os.path.exists(path + ".race"):
        # A person acted between the tick's listing and its claim.
        race = json.load(open(path + ".race")); os.remove(path + ".race")
        p.update({k: v for k, v in race.items() if k in ("labels", "assignees")})
        if "head" in race:
            subprocess.run(["git", "--git-dir", os.environ["STUB_ORIGIN"], "update-ref",
                            "refs/heads/" + p["head_ref"], race["head"]], check=True)
        save()
    print(json.dumps({"head_sha": head(p), "labels": p["labels"], "assignees": p.get("assignees", [])}))
else:
    sys.exit(f"stub adapter: unexpected {cmd}")
PY
cp "$REAL_COMMON/marker.py" "$TMP/common/marker.py"
export STUB_GITEA="$TMP/gitea.json" STUB_ADAPTER="$TMP/common/gitea-pr.py" STUB_REPO="$R" STUB_PR=7
export STUB_CALLS="$TMP/calls" STUB_BEHAVE="$TMP/behave" STUB_CLAIMREC="$CLAIMREC" STUB_ORIGIN="$ORIGIN"
export STUB_PIDS="$TMP/stub-pids"

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
  [ -f "$PWD/.cursor/cli.json" ] && echo "CURSOR_CLI_JSON=present" && python3 -c '
import json, sys
perms = json.load(open(sys.argv[1]))["permissions"]
for kind in ("allow", "deny"):
    for rule in perms[kind]:
        print(f"CURSOR_{kind.upper()} {rule}")' "$PWD/.cursor/cli.json"
  [ -f "$PWD/.agent-pool-context.md" ] && echo "CONTEXT_DIFF_LINES=$(grep -c '^+change' "$PWD/.agent-pool-context.md")"
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
  hang)      sleep 60 & echo $! >> "$STUB_PIDS"; wait $!; success ;;
  resolve-noted)    resolve_text 0 1 0 > "$report"; success ;;
  resolve-deferred) resolve_text 0 0 1 > "$report"; success ;;
  resolve-fix)      commit_fix; resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"; success ;;
  resolve-repoint)
    # Commit, then point the worktree's .git at a gitdir of the worker's choosing.
    commit_fix; resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"
    printf 'gitdir: /nonexistent/worker-owned-gitdir\n' > .git; success ;;
  resolve-toolconf-cursor)
    commit_fix; mkdir -p .cursor; echo '{"permissions":{"allow":["Shell(*)"]}}' > .cursor/cli.json
    git add -f .cursor/cli.json; git commit -q -m "chore: tool config"
    resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"; success ;;
  resolve-toolconf-claude)
    commit_fix; mkdir -p .claude; echo '{}' > .claude/settings.json
    git add .claude/settings.json; git commit -q -m "chore: tool config"
    resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"; success ;;
  resolve-context)
    commit_fix; git add -f .agent-pool-context.md; git commit -q -m "chore: context"
    resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"; success ;;
  resolve-secret-msg)
    echo "fix $RANDOM" >> f.txt; git add f.txt
    git commit -q -m "fix: something" -m "token: 3f9a0c1d2e4b5a6978c0d1e2f3a4b5c6d7e8f901"
    resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"; success ;;
  resolve-secret-diff)
    echo "GITEA_TOKEN=3f9a0c1d2e4b5a6978c0d1e2f3a4b5c6d7e8f901" >> f.txt; git add f.txt; git commit -q -m "fix: config"
    resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"; success ;;
  resolve-lag)
    commit_fix; cat "$STUB_BEHAVE/lag" > "$STUB_GITEA.lag"
    resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"; success ;;
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
    echo $! > "$STUB_CALLS/grandchild.pid"; echo $! >> "$STUB_PIDS"
    if [ "$behave" = steal ]; then sleep 300 & echo $! >> "$STUB_PIDS"; wait $!; fi
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
  rm -rf "$TMP/state" "$TMP/calls"/* "$TMP/behave"/* "$STUB_GITEA.writes" "$STUB_GITEA.race" "$STUB_GITEA.lag" \
    "$STUB_GITEA.faildone"
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
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-repoint
tick
expect "S2: a worker that repoints its .git still has its commit read through the main clone" "$(git --git-dir "$ORIGIN" log -1 --format=%s feature/x)" "fix: something"
expect "S2: and the resolve is done" "$(labels)" "agent:done"
for tc in cursor claude; do
  reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
  behave claude "resolve-toolconf-$tc"
  tick
  expect "S3: commits touching .$tc/ are never pushed" "$(origin_head)" "$SHA"
  expect "S3: and go to needs-human (.$tc/)" "$(labels)" "agent:needs-human"
  expect "S3: with the reason (.$tc/)" "$(comments)" "touch agent tool configuration"
done
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-context
tick
expect "r4#5: a commit adding the context file is never pushed" "$(origin_head)" "$SHA"
expect "r4#5: and the reason is given" "$(comments)" "touch agent tool configuration"
for leak in msg diff; do
  reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
  behave claude "resolve-secret-$leak"
  tick
  expect "r4#2: a credential in the commit $leak is never pushed" "$(origin_head)" "$SHA"
  expect "r4#2: and goes to needs-human ($leak)" "$(labels)" "agent:needs-human"
  expect "r4#2: with the reason ($leak)" "$(comments)" "contain a credential or token-shaped string"
  expect_not "r4#2: and the secret itself is not repeated in the comment ($leak)" "$(comments)" "3f9a0c1d2e4b"
done
for lag in 3 99; do
  reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
  behave claude resolve-lag; echo "$lag" > "$TMP/behave/lag"
  AGENT_POOL_HEAD_SETTLE="0 0 0 0" tick
  expect "S6: a resolve is verified against the pushed head while Gitea lags ($lag reads)" "$(labels)" "agent:done"
  expect_not "S6: not 'head never moved' ($lag reads)" "$(cat "$TMP/out.txt")" "never moved"
done

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
echo "commit rules: resolve may commit only with git commit -m (no --trailer, #29), review may not commit at all"
claude_allows() { calls claude | sed -n '/^ARG --allowedTools$/,/^ARG --disallowedTools$/p'; }
claude_denies() { calls claude | sed -n '/^ARG --disallowedTools$/,/^[^A]/p'; }
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave cursor-agent resolve-fix
PROVIDER_ORDER=cursor tick
expect_not "cursor resolve cli.json does not allow git commit --trailer" "$(calls cursor-agent | grep '^CURSOR_ALLOW')" "git commit --trailer"
expect "cursor resolve cli.json still allows git commit -m" "$(calls cursor-agent)" "CURSOR_ALLOW Shell(git commit -m)"
for rule in 'git push' 'git push --force' 'git commit -a' 'git commit --all' 'git commit --amend' 'git commit -F' 'git commit --file'; do
  expect "cursor resolve cli.json still denies $rule" "$(calls cursor-agent)" "CURSOR_DENY Shell($rule)"
done
expect_not "cursor resolve cli.json allows no push" "$(calls cursor-agent | grep '^CURSOR_ALLOW')" "git push"
expect "a commit from cursor is pushed by the controller" "$(git --git-dir "$ORIGIN" log -1 --format=%s feature/x)" "fix: something"
expect "and the resolve is done" "$(labels)" "agent:done"
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-fix
tick
expect_not "claude resolve does not allow git commit --trailer" "$(claude_allows)" "git commit --trailer"
expect "claude resolve still allows git commit -m" "$(claude_allows)" "ARG Bash(git commit -m *)"
expect_not "claude resolve allows no push" "$(claude_allows)" "git push"
for rule in 'git push*' 'git push --force*' 'git commit -a*' 'git commit --amend*' 'git commit -F*' 'git commit *--file*'; do
  expect "claude resolve still denies $rule" "$(claude_denies)" "ARG Bash($rule)"
done
expect "a commit from claude is pushed by the controller" "$(git --git-dir "$ORIGIN" log -1 --format=%s feature/x)" "fix: something"
reset '["agent:ready"]'
behave cursor-agent ok
PROVIDER_ORDER=cursor tick
expect_not "cursor review cli.json does not allow git commit --trailer" "$(calls cursor-agent | grep '^CURSOR_ALLOW')" "git commit"
expect "cursor review cli.json denies git commit" "$(calls cursor-agent)" "CURSOR_DENY Shell(git commit)"
reset '["agent:ready"]'
behave claude ok
tick
expect_not "claude review does not allow git commit --trailer" "$(claude_allows)" "git commit"
expect "claude review denies git commit" "$(claude_denies)" "ARG Bash(git commit*)"

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
aid="$(AGENT_POOL_NOW=$(( $(date +%s) - 10000 )) python3 "$CLAIMREC" claim --repo $R --pr 7 --worker w --provider grok --deadline-secs 100)"
mkdir -p "$TMP/state/published"; : > "$TMP/state/published/owner_repo__7.$aid"
behave claude ok
tick
expect "L4: a stale claim whose work was published (only its release failed) is requeued" "$(cat "$TMP/out.txt")" "only the release failed"
expect "L4: and its provider is not cooled down" "$(cooldown_doc grok)" "none"
expect "L4: the published marks are cleared once consumed or released" "$(ls -A "$TMP/state/published" | wc -l)" "0"
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
echo "S1: the claim re-reads the PR live under the lock"
for race in '{"labels":["agent:ready","agent:needs-human"]}' '{"labels":[]}' '{"assignees":["craig"]}' \
            '{"labels":["agent:ready","status: in-progress"]}' "{\"head\":\"$(git --git-dir "$ORIGIN" rev-parse master)\"}"; do
  reset '["agent:ready"]'
  echo "$race" > "$STUB_GITEA.race"
  behave claude ok
  tick
  expect "a change after listing ($race) refuses the claim" "$(cat "$TMP/out.txt")" "changed since it was listed"
  expect "and no provider ran ($race)" "$(ncalls claude)" "0"
  expect "and nothing was written to Gitea ($race)" "$(w="$(writes)"; echo "${w:-none}")" "none"
  expect "and no claim record is left ($race)" "$(record)" "{}"
done
reset '["agent:ready"]' '["pool-bot"]'
behave claude ok
AGENT_POOL_BOT=pool-bot tick
expect "the pool's own assignee does not refuse the claim" "$(comments)" "pulse-review:v1 head=$SHA"

echo
echo "pre-verify: already-done work is settled without a provider"
reset '["agent:ready"]' '[]' "$CLEAN_MARKER"
tick
expect "a PR whose head already has a clean review is agent:done" "$(labels)" "agent:done"
expect "without spawning a provider" "$(ncalls claude)" "0"
RESOLVE_DONE="$(python3 -c 'import json,sys; s,r=sys.argv[1:]; print(json.dumps([
  {"id":1,"user":"bot","created_at":"","body":f"## Automated review\n1. x\n<!-- pulse-review:v1 head={s} findings=1 -->"},
  {"id":2,"user":"bot","created_at":"","body":f"## Automated resolve\n<!-- pulse-resolve:v1 head={r} reviewed={s} fixed=1 noted=0 deferred=0 -->"}]))' "$SHA" "$RESOLVED")"
reset '["agent:ready"]' '[]' "$RESOLVE_DONE"
git --git-dir "$ORIGIN" update-ref refs/heads/feature/x "$RESOLVED"
PROVIDER_ORDER=agy tick
expect "G6: an already-verified resolve is settled even when no provider takes resolve jobs" "$(labels)" "agent:done"
expect "G6: the log says why" "$(cat "$TMP/out.txt")" "already verified at $RESOLVED"
expect_not "G6: it is not skipped for want of a resolve provider" "$(cat "$TMP/out.txt")" "no eligible provider takes resolve"
expect "G6: and no provider ran" "$(ncalls agy)" "0"
reset '["agent:ready"]' '[]' "$CLEAN_MARKER"
AGENT_POOL_MAX_JOBS=0 tick
expect "r4#7: a settled PR is settled even with no job slots left" "$(labels)" "agent:done"
reset '["agent:ready"]'
python3 - "$STUB_GITEA" "$CLEAN_MARKER" <<'PY'
import json, sys
path, comments = sys.argv[1:]
st = json.load(open(path))
st["prs"]["8"] = dict(st["prs"]["7"], labels=["agent:ready"], comments=json.loads(comments))
json.dump(st, open(path, "w"))
PY
behave claude limit
tick
expect "r4#7: once every provider cools down, later settled PRs are still settled" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["prs"]["8"]["labels"])' "$STUB_GITEA")" "agent:done"
expect "r4#7: the log says the tick only settles from there" "$(cat "$TMP/out.txt")" "only settling from here"
reset '["agent:ready"]' '[]' "$CLEAN_MARKER"
: > "$STUB_GITEA.faildone"
tick
expect "r4#6: a settled job whose release fails keeps its claim for reconciliation" "$(record)" "attempt_id"
rm -f "$STUB_GITEA.faildone"
AGENT_POOL_NOW=$(( $(date +%s) + 100000 )) tick
expect "r4#6: the stale claim of a settled job is requeued without a strike" "$(cat "$TMP/out.txt")" "only the release failed"
expect "r4#6: and nobody is cooled down" "$(ls "$TMP/state/cooldowns" 2>/dev/null | wc -l)" "0"
expect "r4#6: the job then settles" "$(labels)" "agent:done"

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
agy_prompt="$(cat "$TMP/state/runs/prompt-7-"*-agy.txt)"
expect "G3: agy reviews with the no-commands prompt" "$agy_prompt" "you cannot run commands"
expect_not "G3: which never asks for git diff" "$agy_prompt" "git diff"
expect_not "G3: nor for an adapter command" "$agy_prompt" "gitea-pr.py"
expect "G3: it points at the controller's context file in the worktree" "$agy_prompt" "$TMP/wt/pool-7-"
expect "G3: the controller wrote the diff into the context file before agy ran" "$(calls agy)" "CONTEXT_DIFF_LINES=1"
expect "G3: the context file never reaches a commit" "$(cat "$TMP/main/.git/info/exclude")" "/.agent-pool-context.md"
expect "G3: and the main clone stays clean" "$([ -z "$(git -C "$TMP/main" status --porcelain)" ] && echo clean || echo dirty)" "clean"
expect_not "G3: the diff stays off agy's command line" "$(calls agy | grep '^ARG')" "diff --git"
reset '["agent:ready"]'
behave agy final-only
printf 'custom agy review __SHA__ <!-- pulse-review:v1 head=__SHA__ findings=0 -->\n' > "$TMP/agy-custom.txt"
AGENT_POOL_PROMPT_AGY_REVIEW="$TMP/agy-custom.txt" PROVIDER_ORDER=agy tick
expect "G3: AGENT_POOL_PROMPT_AGY_REVIEW overrides the agy review prompt" "$(cat "$TMP/state/runs/prompt-7-"*-agy.txt)" "custom agy review $SHA"
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
expect "G4: the timed-out provider pauses briefly" "$(cooldown_doc claude)" '"seconds": 900'
expect "G4: with no strike" "$(cooldown_doc claude)" '"strikes": 0'
expect "G4: and the log says so" "$(cat "$TMP/out.txt")" "TIMEOUT [claude]"
reset '["agent:ready"]'
behave claude hang; behave cursor-agent ok
WORKER_TIMEOUT=2 AGENT_POOL_FAST_FAIL_SECS=0 PROVIDER_ORDER=claude,cursor tick
expect "G4: a timeout falls through to the next provider in the same tick" "$(comments)" "pulse-review:v1 head=$SHA findings=2"
expect "G4: which ran under its own attempt" "$(calls cursor-agent)" "CLAIM_PROVIDER=cursor"
reset '["agent:ready"]'
mkdir -p "$TMP/state/cooldowns"
python3 "$ROOT/agent-pool/scripts/cooldown.py" record --provider claude --reason limit >/dev/null
python3 "$ROOT/agent-pool/scripts/cooldown.py" record --provider claude --reason timeout --seconds 900 >/dev/null
expect "G4: a timeout pause never shortens a longer limit cooldown" "$(cooldown_doc claude)" '"strikes": 1'
left="$(python3 "$ROOT/agent-pool/scripts/cooldown.py" active --provider claude)"
expect "G4: (the limit's hour still stands)" "$([ "${left:-0}" -gt 3000 ] && echo hour || echo "only ${left}s")" "hour"
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
expect "G5: the resolve prompt has the final-response fallback" "$(cat "$REAL_COMMON/prompts/resolve.generic.txt")" "If you cannot write files, make the complete report your final response instead"
expect "L3: the resolve count covers only the review's numbered findings" "$(cat "$REAL_COMMON/prompts/resolve.generic.txt")" "thread replies are never counted"
expect "L3: thread replies are listed separately" "$(cat "$REAL_COMMON/prompts/resolve.generic.txt")" "list Thread replies"
expect_not "L3: inline threads are no longer counted as findings" "$(cat "$REAL_COMMON/prompts/resolve.generic.txt")" "Treat each as one finding"
expect_not "no generic or agy prompt uses an em or en dash" "$(cat "$REAL_COMMON/prompts/"*.generic.txt "$REAL_COMMON/prompts/review.agy.txt")" "—"
expect_not "the generic prompts use no Claude-only skill" "$(cat "$REAL_COMMON/prompts/review.generic.txt" "$REAL_COMMON/prompts/resolve.generic.txt")" "mattpocock-skills"
expect_not "no prompt tells a worker to post a comment" "$(cat "$REAL_COMMON/prompts/review.generic.txt" "$REAL_COMMON/prompts/resolve.generic.txt")" "__ADAPTER__ comment "
expect_not "no prompt tells a worker to push" "$(cat "$REAL_COMMON/prompts/review.generic.txt" "$REAL_COMMON/prompts/resolve.generic.txt")" "git push origin"
expect "a rendered prompt has no unfilled placeholder" "$(cat "$TMP/state/runs/prompt-7-"*-codex.txt | grep -c '__[A-Z_]*__')" "0"

echo
echo "TheNightCrew issue hold (opt-in check against GET /repos/{repo}/issue-hold)"
# A stub hold script whose behavior is the word in hold-state; every invocation is recorded.
cat > "$TMP/common/nightcrew-issue-hold.py" <<'PY'
import os, sys, time
here = os.path.dirname(os.path.abspath(sys.argv[0]))
open(os.path.join(here, "hold-calls"), "a").write(" ".join(sys.argv[1:]) + "\n")
mode = open(os.path.join(here, "hold-state")).read().strip()
if mode == "busy": print("busy")
elif mode == "clear": print("clear")
elif mode == "clear-rc1": print("clear"); sys.exit(1)
elif mode == "clear-twice": print("clear"); print("clear")
elif mode == "padded": print(" clear")
elif mode == "crash": sys.exit(1)
elif mode == "hang": time.sleep(30); print("clear")
elif mode == "clear-then-busy":
    n = sum(1 for _ in open(os.path.join(here, "hold-calls")))
    print("clear" if n <= 2 else "busy")
PY
hold_calls() { if [ -f "$TMP/common/hold-calls" ]; then wc -l < "$TMP/common/hold-calls" | tr -d ' '; else echo 0; fi; }
hold_reset() { reset '["agent:ready"]'; behave claude ok; rm -f "$TMP/common/hold-calls"; echo "$1" > "$TMP/common/hold-state"; }
export AGENT_POOL_NIGHTCREW_HOLD_SCRIPT="$TMP/common/nightcrew-issue-hold.py"
unset AGENT_POOL_NIGHTCREW_HOLD AGENT_POOL_NIGHTCREW_BOT AGENT_POOL_NIGHTCREW_TIMEOUT

hold_reset busy
tick
expect "not opted in: the hold check is never run" "$(hold_calls)" "0"
expect "not opted in: claiming is unaffected" "$(ncalls claude)" "1"

export AGENT_POOL_NIGHTCREW_HOLD=1
hold_reset busy
tick
expect "opted in: the check runs once per tick for this repo" "$(cat "$TMP/common/hold-calls" 2>/dev/null)" "--repo $R"
expect "no provider is invoked while TheNightCrew reports the repo held" "$(ncalls claude)" "0"
expect "the PR is left exactly as queued, not claimed" "$(labels)" "agent:ready"
expect "the hold is logged" "$(cat "$TMP/out.txt")" "TheNightCrew reports active issue/maintenance work"

echo clear > "$TMP/common/hold-state"
tick
expect "claiming resumes once the hold is released" "$(ncalls claude)" "1"
expect "the review lands normally" "$(comments)" "pulse-review:v1"

echo "  (a cached clear from before the first claim must not cover the second, Codex PR #13)"
hold_reset clear-then-busy
python3 - "$STUB_GITEA" <<'PY'
import json, sys
path = sys.argv[1]
st = json.load(open(path))
st["prs"]["8"] = dict(st["prs"]["7"], labels=["agent:ready"], comments=[])
st["prs"]["9"] = dict(st["prs"]["7"], labels=["agent:ready"], comments=[])
json.dump(st, open(path, "w"))
PY
tick
expect "the first job still claims and runs (hold was clear)" "$(ncalls claude)" "1"
expect "pr 7 ran and requeued for resolve (review with findings, not a crash or a skip)" \
  "$(python3 "$STUB_ADAPTER" comments --repo $R --pr 7)" "pulse-review:v1"
expect "pr 8 was never touched -- skipped before any provider ran" \
  "$(python3 "$STUB_ADAPTER" comments --repo $R --pr 8)" "[]"
expect "pr 8 is skipped (hold went busy between claims, not cached from tick start)" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["prs"]["8"]["labels"])' "$STUB_GITEA")" "agent:ready"
expect "the rechecked skip is logged" "$(cat "$TMP/out.txt")" "rechecked before claim"
expect "pr 9 was never touched either" "$(python3 "$STUB_ADAPTER" comments --repo "$R" --pr 9)" "[]"
expect "the check ran three times: the early filter, job 1, then job 2's busy answer stops the rest" "$(hold_calls)" "3"

for mode in crash clear-rc1 clear-twice padded; do
  hold_reset "$mode"
  tick
  expect "a hold check that answers '$mode' claims nothing" "$(ncalls claude)" "0"
  expect "the PR stays queued after a '$mode' hold check" "$(labels)" "agent:ready"
  expect "a '$mode' hold check is logged as failing closed" "$(cat "$TMP/out.txt")" "failing closed"
done

hold_reset clear
AGENT_POOL_NIGHTCREW_HOLD_SCRIPT="$TMP/common/no-such-hold-script.py" tick
expect "a missing hold script claims nothing" "$(ncalls claude)" "0"

hold_reset hang
started=$(date +%s)
AGENT_POOL_NIGHTCREW_TIMEOUT=1 tick
expect "a hung hold check claims nothing" "$(ncalls claude)" "0"
expect "a hung hold check is cut off by the outer bound" "$(( $(date +%s) - started < 20 ))" "1"

hold_reset clear
AGENT_POOL_NIGHTCREW_TIMEOUT=soon tick
expect "an invalid AGENT_POOL_NIGHTCREW_TIMEOUT claims nothing" "$(ncalls claude)" "0"
expect "an invalid timeout is logged" "$(cat "$TMP/out.txt")" "AGENT_POOL_NIGHTCREW_TIMEOUT"

for value in yes on true TRUE ture; do
  hold_reset busy
  AGENT_POOL_NIGHTCREW_HOLD="$value" tick
  expect "AGENT_POOL_NIGHTCREW_HOLD=$value turns the check on" "$(ncalls claude)" "0"
done
for value in 0 off false no; do
  hold_reset busy
  AGENT_POOL_NIGHTCREW_HOLD="$value" tick
  expect "AGENT_POOL_NIGHTCREW_HOLD=$value leaves the check off" "$(ncalls claude)" "1"
done

unset AGENT_POOL_NIGHTCREW_HOLD
echo "  (upgrade from the Gitea bot-assignee proxy)"
hold_reset busy
AGENT_POOL_NIGHTCREW_BOT=night-crew-bot tick
expect "the old AGENT_POOL_NIGHTCREW_BOT alone still turns the check on" "$(hold_calls)" "1"
expect "the old variable alone still blocks a held repo" "$(ncalls claude)" "0"
expect "the old variable is reported as deprecated" "$(cat "$TMP/out.txt")" "AGENT_POOL_NIGHTCREW_BOT is deprecated"
expect_not "the old bot login is not passed to the new check" "$(cat "$TMP/common/hold-calls" 2>/dev/null)" "night-crew-bot"
hold_reset busy
AGENT_POOL_NIGHTCREW_BOT=night-crew-bot AGENT_POOL_NIGHTCREW_HOLD=0 tick
expect "AGENT_POOL_NIGHTCREW_HOLD=0 cannot switch off a still-set old variable" "$(ncalls claude)" "0"

echo "  (the real hold script, installed layout, loopback fake NightCrew)"
unset AGENT_POOL_NIGHTCREW_HOLD_SCRIPT
INSTALLED="$TMP/installed/agent-pool"
mkdir -p "$INSTALLED"
cp -R "$ROOT/agent-pool/bin" "$ROOT/agent-pool/scripts" "$INSTALLED/"
python3 "$ROOT/agent-pool/tests/fake-nightcrew.py" "$TMP/nc.json" "$TMP/nc.log" "$TMP/nc.port" &
echo $! >> "$TMP/server-pids"
for _ in $(seq 1 50); do [ -s "$TMP/nc.port" ] && break; sleep 0.1; done
NC_SECRET="nc-provider-test-token-91c4"
mkdir -p "$HOME/.config/pulse"
installed_tick() {
  AGENT_POOL_COMMON="$REAL_COMMON" AGENT_POOL_NIGHTCREW_HOLD=1 \
    AGENT_POOL_NIGHTCREW_URL="http://127.0.0.1:$(cat "$TMP/nc.port")/api" \
    bash "$INSTALLED/bin/prod-common.sh" > "$TMP/out.txt" 2>&1
}
nc_answer() { printf '{"status": %s, "body": %s}' "$1" "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$2")" > "$TMP/nc.json"; : > "$TMP/nc.log"; }

hold_reset unused
nc_answer 200 "{\"repo\": \"$R\", \"held\": false}"
installed_tick
expect "no Worker token file: nothing is claimed" "$(ncalls claude)" "0"
expect "no Worker token file: no request is sent" "$(wc -l < "$TMP/nc.log" | tr -d ' ')" "0"
printf '%s\n' "$NC_SECRET" > "$HOME/.config/pulse/night_crew_token"

hold_reset unused
nc_answer 200 "{\"repo\": \"$R\", \"held\": true}"
installed_tick
expect "installed: a held repo claims nothing" "$(ncalls claude)" "0"
expect "installed: the endpoint is asked for this repo" "$(cat "$TMP/nc.log")" "\"path\": \"/api/repos/$R/issue-hold\""
expect "installed: with the Worker token as a bearer" "$(cat "$TMP/nc.log")" "\"authorization\": \"Bearer $NC_SECRET\""
nc_answer 200 "{\"repo\": \"$R\", \"held\": false}"
installed_tick
expect "installed: the released repo is claimed on the next tick" "$(ncalls claude)" "1"

for answer in "401|{\"repo\": \"$R\", \"held\": false}" "403|{\"repo\": \"$R\", \"held\": false}" \
              "500|{\"repo\": \"$R\", \"held\": false}" "200|{\"repo\": \"owner/other\", \"held\": false}" \
              "200|{\"repo\": \"$R\", \"held\": \"false\"}" "200|{\"repo\": \"$R\"}" "200|not json"; do
  hold_reset unused
  nc_answer "${answer%%|*}" "${answer#*|}"
  installed_tick
  expect "installed: HTTP ${answer%%|*} ${answer#*|} claims nothing" "$(ncalls claude)" "0"
done
expect_not "installed: the Worker token never reaches the pool log" "$(cat "$TMP/state/pool.log" "$TMP/out.txt" 2>/dev/null)" "$NC_SECRET"

unset AGENT_POOL_NIGHTCREW_HOLD AGENT_POOL_NIGHTCREW_BOT AGENT_POOL_NIGHTCREW_TIMEOUT

echo
echo "entrypoints: prod-<provider>.sh ticks what repos.toml enables"
EP="$ROOT/agent-pool/bin"
CONF="$TMP/repos.toml"
export AGENT_POOL_CONFIG="$CONF"
conf() { printf '%s\n' "$@" > "$CONF"; }
# The harness exports AGENT_POOL_REPO/MAIN/WORKER_ID for direct ticks; an entrypoint takes them
# from the config instead.
entry() { # provider [VAR=value...]
  local p="$1"; shift
  env -u AGENT_POOL_REPO -u AGENT_POOL_MAIN -u AGENT_POOL_WORKER_ID "$@" bash "$EP/prod-$p.sh" > "$TMP/out.txt" 2>&1
  TICK_RC=$?
}
repoconf() { python3 "$ROOT/agent-pool/scripts/repoconfig.py" "$@" 2>&1; }
HOST="$(hostname -s 2>/dev/null || echo host)"

conf '[repos."owner/repo"]' "main = \"$TMP/main\""
reset '["agent:ready"]'
behave claude ok
entry claude
expect "a repo with no abilities key is reviewed" "$(comments)" "pulse-review:v1 head=$SHA findings=2"
expect "the entrypoint ticks as <host>-claude" "$(cat "$TMP/out.txt")" "claimed by $HOST-claude for review"
expect "and says which abilities it ticks with" "$(cat "$TMP/out.txt")" "owner/repo: tick as $HOST-claude with abilities review"
expect "the entrypoint tick is a normal exit" "$TICK_RC" "0"
entry claude
expect "the default is review only: the queued resolve is skipped" "$(cat "$TMP/out.txt")" \
  "resolve is not an enabled ability for owner/repo here (enabled: review)"
expect "claude never ran for the resolve" "$(ncalls claude)" "1"
expect "the resolve stays queued" "$(labels)" "agent:ready"

conf '[repos."owner/repo"]' "main = \"$TMP/main\"" 'abilities = ["review", "resolve"]'
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-noted
entry claude
expect "with resolve enabled the entrypoint resolves" "$(labels)" "agent:done"

conf '[pool]' 'providers = ["claude"]'
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-noted
AGENT_POOL_REPO="$R" AGENT_POOL_MAIN="$TMP/main" bash "$EP/prod-claude.sh" > "$TMP/out.txt" 2>&1
expect "a repo absent from repos.toml (named by AGENT_POOL_REPO) is review only" "$(cat "$TMP/out.txt")" \
  "resolve is not an enabled ability for owner/repo here (enabled: review)"
expect "so nothing ran on it" "$(ncalls claude)" "0"

conf '[repos."owner/repo"]' "main = \"$TMP/main\""
for p in claude cursor grok agy codex; do
  cli="$p"; [ "$p" = cursor ] && cli=cursor-agent
  reset '["agent:ready"]'
  behave "$cli" final-only
  entry "$p" PROVIDER_ORDER=claude,cursor,grok,agy,codex AGENT_POOL_MODEL_CODEX=test-codex
  expect "prod-$p.sh runs $p" "$(comments)" "pulse-review:v1 head=$SHA findings=2"
  others=0
  for o in claude cursor-agent grok agy codex; do [ "$o" = "$cli" ] || others=$((others + $(ncalls "$o"))); done
  expect "prod-$p.sh runs no other provider, whatever PROVIDER_ORDER says" "$others" "0"
  expect "prod-$p.sh ticks as <host>-$p" "$(cat "$TMP/out.txt")" "claimed by $HOST-$p"
done
ln -s "$EP/prod-claude.sh" "$BIN/prod-claude.sh"
reset '["agent:ready"]'
behave claude ok
env -u AGENT_POOL_REPO -u AGENT_POOL_MAIN bash "$BIN/prod-claude.sh" > "$TMP/out.txt" 2>&1
expect "an entrypoint installed as a symlink still finds prod-common.sh" "$(comments)" "pulse-review:v1"
rm -f "$BIN/prod-claude.sh"

echo "  (agy never resolves)"
conf '[repos."owner/repo"]' "main = \"$TMP/main\"" 'abilities = ["plan", "review", "prototype", "test-author", "resolve"]' \
  '[repos."owner/repo".providers.agy]' 'abilities = ["review", "resolve"]'
expect "repoconfig caps agy below resolve" "$(repoconf abilities --repo owner/repo --provider agy)" "review"
expect_not "even when its own table lists resolve" "$(python3 "$ROOT/agent-pool/scripts/repoconfig.py" abilities --repo owner/repo --provider agy 2>/dev/null)" "resolve"
expect "and says it ignored that" "$(repoconf abilities --repo owner/repo --provider agy)" "agy can never take resolve; ignored"
expect "claude keeps resolve on the same repo" "$(repoconf abilities --repo owner/repo --provider claude)" "review,prototype,test-author,resolve"
conf '[repos."owner/repo"]' "main = \"$TMP/main\"" 'abilities = ["plan", "review", "prototype", "test-author", "resolve"]'
expect "agy gets plan, review, prototype and test-author" "$(repoconf abilities --repo owner/repo --provider agy)" \
  "plan,review,prototype,test-author"
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave agy resolve-noted
entry agy AGY_AUTO_APPROVE=1
expect "prod-agy.sh takes no resolve job, even with AGY_AUTO_APPROVE=1" "$(ncalls agy)" "0"
expect "it says resolve is not enabled for agy" "$(cat "$TMP/out.txt")" "resolve is not an enabled ability"
expect "the resolve stays queued" "$(labels)" "agent:ready"
expect_not "and agy is never given --dangerously-skip-permissions" "$(calls agy)" "dangerously-skip-permissions"
AGENT_POOL_ABILITIES=review,resolve AGY_AUTO_APPROVE=1 PROVIDER_ORDER=agy tick
expect "prod-common.sh refuses agy a resolve under AGENT_POOL_ABILITIES, whatever it lists" "$(cat "$TMP/out.txt")" \
  "no eligible provider takes resolve jobs"
expect "so agy still never ran" "$(ncalls agy)" "0"
reset '["agent:ready"]'
behave agy final-only
entry agy
expect "prod-agy.sh reviews" "$(comments)" "pulse-review:v1 head=$SHA findings=2"
expect "in plan mode" "$(calls agy | tr '\n' ' ')" "ARG --mode ARG plan"

echo "  (roster, config errors, per-repo settings)"
conf '[pool]' 'providers = ["claude"]' '[repos."owner/repo"]' "main = \"$TMP/main\""
reset '["agent:ready"]'
behave grok ok
entry grok
expect "a provider outside the roster ticks nothing" "$(ncalls grok)" "0"
expect "and says so" "$(cat "$TMP/out.txt")" "grok is not in the roster"
expect "which is a normal exit" "$TICK_RC" "0"
for bad in 'abilities = ["reveiw"]' 'abilites = ["review"]' 'abilities = "review"'; do
  conf '[repos."owner/repo"]' "main = \"$TMP/main\"" "$bad"
  reset '["agent:ready"]'
  behave claude ok
  entry claude
  expect "a config with '$bad' is a setup fault (exit 2)" "$TICK_RC" "2"
  expect "and nothing ran ($bad)" "$(ncalls claude)" "0"
done
conf '[repos."owner/repo"' 'main = 1'
entry claude
expect "an unparseable config is a setup fault" "$TICK_RC" "2"
expect "with the reason" "$(cat "$TMP/out.txt")" "the repo config is unusable"
reset '["agent:ready"]'
behave claude ok
AGENT_POOL_ABILITIES=review,bogus tick
expect "an unknown ability in AGENT_POOL_ABILITIES is refused" "$(cat "$TMP/out.txt")" "unknown ability 'bogus'"
expect "and nothing ran" "$(ncalls claude)" "0"
conf '[repos."owner/repo"]' "main = \"$TMP/main\"" 'nightcrew_hold = true'
hold_reset busy
AGENT_POOL_NIGHTCREW_HOLD_SCRIPT="$TMP/common/nightcrew-issue-hold.py" entry claude
expect "nightcrew_hold = true turns the hold check on for that repo" "$(hold_calls)" "1"
expect "so a held repo claims nothing" "$(ncalls claude)" "0"
conf '[repos."owner/repo"]' "main = \"$TMP/main\"" '[repos."owner/other"]' "main = \"$TMP/no-such-clone\""
reset '["agent:ready"]'
behave claude ok
entry claude
expect "each configured repo gets its own tick" "$(cat "$TMP/out.txt")" "owner/other: tick as"
expect "a broken repo does not stop the others" "$(comments)" "pulse-review:v1"
expect "but the run reports its setup fault" "$TICK_RC" "2"
bash "$EP/prod-claude.sh" extra > "$TMP/out.txt" 2>&1
expect "an entrypoint takes no arguments" "$?" "2"

echo "  (a stop that signals only the entrypoint, as systemd's KillMode=mixed does)"
conf '[repos."owner/repo"]' "main = \"$TMP/main\"" '[repos."owner/other"]' "main = \"$TMP/main\""
reset '["agent:ready"]'
behave claude hang
env -u AGENT_POOL_REPO -u AGENT_POOL_MAIN -u AGENT_POOL_WORKER_ID bash "$EP/prod-claude.sh" > "$TMP/out.txt" 2>&1 &
ep=$!
for _ in $(seq 150); do [ "$(ncalls claude)" -ge 1 ] && break; sleep 0.1; done
sleep 1
hung="$(tail -n 1 "$STUB_PIDS")"
t0=$(date +%s); kill -TERM "$ep"; wait "$ep"; rc=$?; took=$(( $(date +%s) - t0 ))
expect "TERM to the entrypoint alone stops the run (exit 143)" "$rc" "143"
expect "without waiting out the worker" "$([ "$took" -lt 30 ] && echo fast || echo "slow ${took}s")" "fast"
expect "the TERM reached the tick, whose exit trap requeued the job" "$(labels)" "agent:ready"
expect "and released its claim" "$(record)" "{}"
expect "the tick says why" "$(cat "$TMP/out.txt")" "exited unexpectedly (exit 143)"
expect "the hung worker was stopped with its group" "$(kill -0 "$hung" 2>/dev/null && echo alive || echo dead)" "dead"
expect "and no further repo was ticked" "$(cat "$TMP/out.txt")" "stopped; ticking no further repos"
expect_not "owner/other never started" "$(cat "$TMP/out.txt")" "owner/other: tick as"
AGENT_POOL_CONFIG="$ROOT/agent-pool/config/repos.example.toml" python3 "$ROOT/agent-pool/scripts/repoconfig.py" check >/dev/null 2>&1
expect "the shipped example config validates" "$?" "0"
expect "a repo the config does not name is review only" "$(repoconf abilities --repo some/where --provider claude)" "review"
unset AGENT_POOL_CONFIG

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
