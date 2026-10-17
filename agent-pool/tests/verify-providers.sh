#!/usr/bin/env bash
# Offline end-to-end cases for the agent pool tick (agent-pool/bin/prod-common.sh).
#
# Everything is stubbed: HOME is a temp directory whose .local/bin holds stub claude,
# cursor-agent, grok, agy and codex CLIs (also first on PATH), the Gitea adapter is a stub that
# keeps PR labels and comments in a JSON file, and the "remote" is a local bare git repo. No real
# provider CLI, no network, no real state directory.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
POOL="$ROOT/agent-pool/bin/prod-common.sh"
REAL_COMMON="$ROOT/skills/pr-loops-common"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
BIN="$HOME/.local/bin"
mkdir -p "$BIN" "$TMP/common" "$TMP/calls" "$TMP/behave"
export PATH="$BIN:$PATH"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
R=owner/repo

# ---------------------------------------------------------------- a local "remote"
git init -q --bare "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/main" 2>/dev/null
git -C "$TMP/main" commit -q --allow-empty -m base
git -C "$TMP/main" push -q origin HEAD:master
git -C "$TMP/main" checkout -q -b feature/x
echo change > "$TMP/main/f.txt"
git -C "$TMP/main" add f.txt
git -C "$TMP/main" commit -q -m change
git -C "$TMP/main" push -q origin feature/x
SHA="$(git -C "$TMP/main" rev-parse HEAD)"
git -C "$TMP/main" checkout -q --detach

# ---------------------------------------------------------------- stub Gitea adapter
cat > "$TMP/common/gitea-pr.py" <<'PY'
import json, os, sys
path = os.environ["STUB_GITEA"]
st = json.load(open(path))
a = sys.argv[1:]
arg = lambda n: a[a.index(n) + 1] if n in a else None
def save():
    json.dump(st, open(path, "w"), indent=1)
def wlog(msg):
    open(path + ".writes", "a").write(msg + "\n")
cmd = a[0]
if cmd == "list":
    print(json.dumps([{"number": int(n), "title": "t", "draft": False, "head_sha": p["head_sha"],
                       "head_ref": p["head_ref"], "base_ref": "master", "author": "human",
                       "is_bot": False, "labels": p["labels"], "assignees": p.get("assignees", []),
                       "url": ""} for n, p in st["prs"].items()]))
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
    print(st["prs"][arg("--pr")]["head_sha"])
else:
    sys.exit(f"stub adapter: unexpected {cmd}")
PY
cp "$REAL_COMMON/marker.py" "$TMP/common/marker.py"
export STUB_GITEA="$TMP/gitea.json" STUB_ADAPTER="$TMP/common/gitea-pr.py" STUB_REPO="$R" STUB_PR=7 STUB_SHA="$SHA"
export STUB_CALLS="$TMP/calls" STUB_BEHAVE="$TMP/behave" STUB_LEASE="$ROOT/agent-pool/scripts/lease.py"

# ---------------------------------------------------------------- stub provider CLIs
cat > "$BIN/stub-provider" <<'SH'
#!/usr/bin/env bash
name="$(basename "$0")"
{
  echo "--- call"
  printf 'ARG %s\n' "$@"
  echo "PWD=$PWD"
  echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY-unset}"
  [ -f "$PWD/.cursor/cli.json" ] && echo "CURSOR_CLI_JSON=present"
} >> "$STUB_CALLS/$name.log"
cat > /dev/null
behave="$(cat "$STUB_BEHAVE/$name" 2>/dev/null || echo ok)"
post() { local f; f="$(mktemp)"; printf '%s\n' "$1" > "$f"
  python3 "$STUB_ADAPTER" comment --repo "$STUB_REPO" --pr "$STUB_PR" --body-file "$f" >/dev/null; rm -f "$f"; }
review() { post "## Automated review
1. [suggestion] something
<!-- pulse-review:v1 head=$STUB_SHA findings=$1 -->"; }
resolve() { post "## Automated resolve
<!-- pulse-resolve:v1 head=$STUB_SHA reviewed=$STUB_SHA fixed=$1 noted=$2 deferred=$3 -->"; }
success() {
  case "$name" in
    claude) echo '{"type":"result","subtype":"success","is_error":false,"result":"done","permission_denials":[]}' ;;
    cursor-agent) echo '{"type":"system","subtype":"init"}'; echo '{"type":"result","subtype":"success","is_error":false,"result":"done"}' ;;
    grok) echo '{"text":"done","stopReason":"EndTurn"}' ;;
    agy) echo '{"status":"SUCCESS","result":"done"}' ;;
    codex) echo done ;;
  esac
}
case "$behave" in
  ok) review 2; success ;;
  silent) success ;;
  resolve-noted) resolve 0 1 0; success ;;
  resolve-deferred) resolve 0 0 1; success ;;
  slow) sleep "${STUB_SLEEP:-4}"; review 2; success ;;
  expire)
    # The lease lapses underneath a running worker; its heartbeat must notice and stop it.
    python3 - "$AGENT_POOL_STATE/leases/owner_repo__$STUB_PR.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1])); doc["expires_at"] = 0
json.dump(doc, open(sys.argv[1], "w"))
PY
    sleep 6; review 2; success ;;
  steal)
    review 2
    # The same stable worker id, restarted: only the fence token separates the two runs.
    AGENT_POOL_NOW=$(( $(date +%s) + 100000 )) python3 "$STUB_LEASE" claim --repo "$STUB_REPO" --pr "$STUB_PR" \
      --mode review --worker "$AGENT_POOL_WORKER_ID" >/dev/null
    success ;;
  limit)
    case "$name" in
      claude) echo '{"type":"result","subtype":"success","is_error":true,"result":"Credit balance is too low"}' ;;
      cursor-agent) echo '{"type":"system","subtype":"init"}'; echo 'Error: rate limit exceeded' >&2; exit 1 ;;
      grok) echo 'HTTP 429 Too Many Requests' >&2; exit 1 ;;
      agy) echo '{"status":"ERROR","error":"quota exceeded"}'; exit 1 ;;
      codex) echo 'insufficient credits' >&2; exit 1 ;;
    esac ;;
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
export AGENT_POOL_MARKER="$TMP/common/marker.py" AGENT_POOL_WORKER_ID=test-worker
export ANTHROPIC_API_KEY=stale-key-for-test PR_LOOP_SKIP_PATTERN=""
unset PROVIDER_ORDER

reset() { # labels-json [assignees-json] [comments-json]
  rm -rf "$TMP/state" "$TMP/calls"/* "$TMP/behave"/* "$STUB_GITEA.writes"
  printf '{"prs":{"7":{"head_sha":"%s","head_ref":"feature/x","labels":%s,"assignees":%s,"comments":%s}}}\n' \
    "$SHA" "$1" "${2:-[]}" "${3:-[]}" > "$STUB_GITEA"
}
behave() { echo "$2" > "$TMP/behave/$1"; }
tick() { # [mode]
  bash "$POOL" "${1:-review}" > "$TMP/out.txt" 2>&1; TICK_RC=$?
}
labels() { python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1]))["prs"]["7"]["labels"]))' "$STUB_GITEA"; }
calls() { cat "$TMP/calls/$1.log" 2>/dev/null; }
ncalls() { grep -c -- '--- call' "$TMP/calls/$1.log" 2>/dev/null || echo 0; }
cooldown_doc() { cat "$TMP/state/cooldowns/$1.json" 2>/dev/null || echo none; }

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
echo "provider limit: cooldown, back to the trigger label"
reset '["review:requested"]'
behave claude limit
tick
expect "the PR goes back to review:requested" "$(labels)" "review:requested"
expect_not "never a silent review:needs-human" "$(labels)" "review:needs-human"
expect "claude gets a 1h cooldown file" "$(cooldown_doc claude)" '"seconds": 3600'
expect "the limit is logged as a limit" "$(cat "$TMP/out.txt")" "LIMIT [claude]"
expect "claude runs with ANTHROPIC_API_KEY unset" "$(calls claude)" "ANTHROPIC_API_KEY=unset"
expect "claude adapter shape" "$(calls claude | tr '\n' ' ')" "ARG -p ARG --output-format ARG json ARG --model ARG opus"
expect "PROVIDER_ORDER unset means claude only; codex is never in the default" "$(ncalls cursor-agent)$(ncalls grok)$(ncalls agy)$(ncalls codex)" "0000"
expect "the tick itself is a normal exit" "$TICK_RC" "0"

echo
echo "next provider picked"
reset '["review:requested"]'
behave claude limit; behave cursor-agent ok
PROVIDER_ORDER=claude,cursor tick
expect "cursor finished the job claude could not" "$(labels)" "review:findings"
expect "claude cooled down" "$(cooldown_doc claude)" '"strikes": 1'
expect "cursor adapter shape" "$(calls cursor-agent | tr '\n' ' ')" "ARG -p ARG --force ARG --trust ARG --workspace ARG $TMP/wt/"
expect "cursor always gets --model" "$(calls cursor-agent | tr '\n' ' ')" "ARG --output-format ARG stream-json ARG --model ARG auto"
expect "cursor saw its per-worktree cli.json" "$(calls cursor-agent)" "CURSOR_CLI_JSON=present"
expect "the worktree config is excluded from commits" "$(cat "$TMP/main/.git/info/exclude")" "/.cursor/cli.json"
expect "the main clone stays clean" "$([ -z "$(git -C "$TMP/main" status --porcelain)" ] && echo clean || echo dirty)" "clean"
reset '["review:requested"]'
mkdir -p "$TMP/state/cooldowns"
behave cursor-agent ok
PROVIDER_ORDER=claude,cursor AGENT_POOL_NOW=$(date +%s) python3 "$ROOT/agent-pool/scripts/cooldown.py" record --provider claude --reason test >/dev/null
PROVIDER_ORDER=claude,cursor tick
expect "a cooling provider is skipped on the next tick" "$(ncalls claude)" "0"
expect "and the next provider is picked first" "$(labels)" "review:findings"

echo
echo "setup faults: no cooldown, reported clearly"
reset '["review:requested"]'
behave cursor-agent denied
PROVIDER_ORDER=cursor tick
expect "cursor permissionDenied gets no cooldown" "$(cooldown_doc cursor)" "none"
expect "the fault is recorded" "$(cat "$TMP/state/faults/cursor.json" 2>/dev/null)" "permissionDenied"
expect "the log says SETUP FAULT" "$(cat "$TMP/out.txt")" "SETUP FAULT [cursor]"
expect "the PR goes back to its trigger, not needs-human" "$(labels)" "review:requested"
expect "the tick exits 2 for a setup fault" "$TICK_RC" "2"
reset '["review:requested"]'
behave agy denied
PROVIDER_ORDER=agy AGENT_POOL_MODEL_AGY=test-model tick
expect "agy denied_actions despite SUCCESS gets no cooldown" "$(cooldown_doc agy)" "none"
expect "agy denied_actions is reported" "$(cat "$TMP/out.txt")" "SETUP FAULT [agy]"
expect "agy runs in the worktree" "$(calls agy)" "PWD=$TMP/wt/"
expect "agy adapter shape" "$(calls agy | tr '\n' ' ')" "ARG -p"
expect "agy flags" "$(calls agy | tr '\n' ' ')" "ARG --output-format ARG json ARG --print-timeout ARG 100s ARG --model ARG test-model"
expect_not "agy auto-approve is opt-in" "$(calls agy)" "dangerously-skip-permissions"
reset '["review:requested"]'
PROVIDER_ORDER=agy tick
expect "agy without a model is a setup fault before any claim" "$(cat "$TMP/out.txt")" "no model configured"
expect "and nothing was claimed" "$(labels)" "review:requested"
expect "and agy never ran" "$(ncalls agy)" "0"

echo
echo "stale fence token blocks writes"
reset '["review:requested"]'
behave claude steal
tick
expect "the worker notices it lost the lease" "$(cat "$TMP/out.txt")" "lease moved on"
expect "its result relabel never happened" "$(labels)" "review:in-progress"
expect "the only write it made was its own claim" "$(cat "$STUB_GITEA.writes")" "label 7 -review:requested +review:in-progress"
expect_not "no finish write after losing the lease" "$(cat "$STUB_GITEA.writes")" "review:findings"
expect "the new holder's lease is left alone" "$(python3 "$STUB_LEASE" show --repo $R --pr 7 | tr -d '\n ')" '"fence":2'
expect_not "and was not released by the stale run" "$(python3 "$STUB_LEASE" show --repo $R --pr 7 | tr -d '\n ')" '"released":true'

echo
echo "expired leases and dead in-progress holds"
reset '["review:in-progress"]'
AGENT_POOL_NOW=$(( $(date +%s) - 10000 )) python3 "$STUB_LEASE" claim --repo $R --pr 7 --mode review --worker dead-worker >/dev/null
behave claude ok
tick
expect "a dead run's in-progress is not a human hold" "$(cat "$TMP/out.txt")" "dead hold"
expect "the expired lease is reclaimed and the job done" "$(labels)" "review:findings"
expect "the reclaim bumped the fence" "$(python3 "$STUB_LEASE" show --repo $R --pr 7)" '"fence": 2'
reset '["review:in-progress"]'
python3 "$STUB_LEASE" claim --repo $R --pr 7 --mode review --worker live-worker >/dev/null
tick
expect "a live lease's hold is respected" "$(cat "$TMP/out.txt")" "held by a live bot lease"
expect "and the provider never ran" "$(ncalls claude)" "0"
reset '["review:requested"]' '["craig"]'
tick
expect "a human assignee is a human hold" "$(cat "$TMP/out.txt")" "held by a human"
reset '["review:requested","status: in-progress"]'
tick
expect "status: in-progress with no lease waits out the grace, not forever" "$(cat "$TMP/out.txt")" "not a human hold"
expect "nothing ran during the grace" "$(ncalls claude)" "0"
AGENT_POOL_ORPHAN_GRACE=0 tick
expect "after the grace the orphan hold is reclaimed" "$(labels)" "review:findings"
expect_not "and the dead status: in-progress label is cleared" "$(labels)" "status: in-progress"
reset '["review:in-progress"]' '[]' "[{\"id\":1,\"user\":\"bot\",\"created_at\":\"\",\"body\":\"<!-- pulse-review:v1 head=$SHA findings=0 -->\"}]"
AGENT_POOL_NOW=$(( $(date +%s) - 10000 )) python3 "$STUB_LEASE" claim --repo $R --pr 7 --mode review --worker dead-worker >/dev/null
tick
expect "a dead run that already posted its marker is finished, not re-run" "$(labels)" "review:clean"
expect "without spawning a provider" "$(ncalls claude)" "0"

echo
echo "heartbeat"
reset '["review:requested"]'
behave claude slow
STUB_SLEEP=4 AGENT_POOL_LEASE_TTL=2 AGENT_POOL_HEARTBEAT=1 tick
expect "a run longer than the TTL keeps its lease by renewing" "$(labels)" "review:findings"
reset '["review:requested"]'
behave claude expire
AGENT_POOL_LEASE_TTL=30 AGENT_POOL_HEARTBEAT=1 tick
expect "a lapsed lease is noticed by the heartbeat" "$(cat "$TMP/out.txt")" "lease moved on"
expect "which stops the provider before it finishes" "$(python3 "$STUB_ADAPTER" comments --repo $R --pr 7)" "[]"
expect "and the worker writes nothing after its claim" "$(labels)" "review:in-progress"
reset '["review:requested"]'
AGENT_POOL_LEASE_TTL=5 AGENT_POOL_HEARTBEAT=5 tick
expect "a heartbeat no shorter than the TTL is refused" "$(cat "$TMP/out.txt")" "must be shorter than"

echo
echo "real verification failures still go to needs-human"
reset '["review:requested"]'
behave claude silent
AGENT_POOL_FAST_FAIL_SECS=0 tick
expect "a slow run with no marker is needs-human" "$(labels)" "review:needs-human"
expect "with a comment saying why" "$(python3 "$STUB_ADAPTER" comments --repo $R --pr 7)" "no review comment carrying the marker"
expect "and no cooldown" "$(cooldown_doc claude)" "none"
reset '["review:requested"]'
behave claude silent
tick
expect "the same run under 90s is the credit-wall fingerprint: a limit" "$(cat "$TMP/out.txt")" "with no marker comment"
expect "so it goes back to the trigger" "$(labels)" "review:requested"
expect "and cools claude down" "$(cooldown_doc claude)" '"strikes": 1'
REVIEW_MARKER="[{\"id\":1,\"user\":\"bot\",\"created_at\":\"\",\"body\":\"<!-- pulse-review:v1 head=$SHA findings=1 -->\"}]"
reset '["review:findings"]' '[]' "$REVIEW_MARKER"
behave claude resolve-deferred
tick resolve
expect "resolve: a blocking finding left for a person is needs-human" "$(labels)" "review:needs-human"
reset '["review:findings"]' '[]' "$REVIEW_MARKER"
behave claude resolve-noted
tick resolve
expect "resolve: a fully accounted, non-blocking disposition is resolved" "$(labels)" "review:resolved"

echo
echo "grok and codex adapters"
reset '["review:requested"]'
behave grok ok
PROVIDER_ORDER=grok tick
expect "grok finished the job" "$(labels)" "review:findings"
expect "grok adapter shape" "$(calls grok | tr '\n' ' ')" "ARG --cwd ARG $TMP/wt/"
expect "grok prompt file and JSON" "$(calls grok | tr '\n' ' ')" "ARG --prompt-file ARG $TMP/state/runs/prompt-7-f1-grok.txt ARG --output-format ARG json ARG --permission-mode ARG bypassPermissions"
expect "grok deny rules" "$(calls grok | tr '\n' ' ')" "ARG --deny ARG Bash(git push --force*)"
expect "grok review cannot commit" "$(calls grok | tr '\n' ' ')" "ARG --deny ARG Bash(git commit *)"
expect "grok model last" "$(calls grok | tr '\n' ' ')" "ARG -m ARG grok-build"
reset '["review:requested"]'
behave grok limit
PROVIDER_ORDER=grok tick
expect "grok 429 cools grok down" "$(cooldown_doc grok)" '"strikes": 1'
reset '["review:requested"]'
behave codex ok
PROVIDER_ORDER=codex AGENT_POOL_MODEL_CODEX=test-codex tick
expect "the codex slot works when asked for" "$(labels)" "review:findings"
expect "codex adapter shape" "$(calls codex | tr '\n' ' ')" "ARG exec ARG --ephemeral ARG --sandbox ARG workspace-write"

echo
echo "prompts"
expect "the generic resolve prompt names files to stage" "$(cat "$REAL_COMMON/prompts/resolve.generic.txt")" "git add path/to/first/file"
expect_not "the generic prompts use no Claude-only skill" "$(cat "$REAL_COMMON/prompts/review.generic.txt" "$REAL_COMMON/prompts/resolve.generic.txt")" "mattpocock-skills"
expect "a rendered prompt has no unfilled placeholder" "$(grep -c '__[A-Z]*__' "$TMP/state/runs/prompt-7-f1-codex.txt")" "0"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
