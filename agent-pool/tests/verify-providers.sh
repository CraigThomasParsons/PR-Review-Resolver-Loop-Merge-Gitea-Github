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
# A throwaway controller signing key, made for this run only and deleted with $TMP (#30).
mkdir -p "$TMP/signing"; chmod 700 "$TMP/signing"
ssh-keygen -q -t ed25519 -N '' -C agent-pool-test -f "$TMP/signing/key" </dev/null >/dev/null
printf 'agent-pool@localhost namespaces="git" %s\n' "$(cut -d' ' -f1,2 "$TMP/signing/key.pub")" > "$TMP/signing/allowed_signers"
export AGENT_POOL_SIGNING_KEY="$TMP/signing/key"
R=owner/repo
ORIGIN="$TMP/origin.git"
ODD_REF='feature/a|b&c'

# ---------------------------------------------------------------- a local "remote"
git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$TMP/main" 2>/dev/null
git -C "$TMP/main" commit -q --allow-empty -m base
# A base branch with no gate manifest at all.
git -C "$TMP/main" push -q origin HEAD:refs/heads/bare
# The pinned gate manifest lives on the base branch; every resolve below is gated by it.
mkdir -p "$TMP/main/.agent-pool"
cat > "$TMP/main/.agent-pool/gates.toml" <<'EOF'
version = 1
protect = ["justfile"]

[defaults]
timeout = 4
budget  = 30

[[gate]]
name  = "unit"
argv  = ["just", "gate"]
paths = ["*.txt", "src/**"]
EOF
printf 'gate:\n\ttrue\n' > "$TMP/main/justfile"
git -C "$TMP/main" add .agent-pool/gates.toml justfile
git -C "$TMP/main" commit -q -m "gates manifest"
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
# A PR whose own (human) commit rewrites the manifest: gates still come from its base.
git -C "$TMP/main" checkout -q --detach "$SHA"
sed -i 's/"just", "gate"/"just", "evil"/' "$TMP/main/.agent-pool/gates.toml"
git -C "$TMP/main" commit -q -am "human: change the gates in the PR"
git -C "$TMP/main" push -q origin HEAD:refs/heads/feature/gatepr
GATEPR_SHA="$(git -C "$TMP/main" rev-parse HEAD)"
# A PR whose own commit adds a filter attribute that global config or the env would define.
git -C "$TMP/main" checkout -q --detach "$SHA"
echo ORIGINAL > "$TMP/main/payload.txt"
echo 'payload.txt filter=evil' > "$TMP/main/.gitattributes"
git -C "$TMP/main" add payload.txt .gitattributes
git -C "$TMP/main" commit -q -m "human: attributes"
git -C "$TMP/main" push -q origin HEAD:refs/heads/feature/attr
ATTR_SHA="$(git -C "$TMP/main" rev-parse HEAD)"
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
                       "head_ref": p["head_ref"], "base_ref": p.get("base_ref", "master"), "author": "human",
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
elif cmd == "threads":
    print(json.dumps(st["prs"][arg("--pr")].get("threads", [])))
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
  [ -f "$PWD/.agent-pool-context.md" ] && grep -q '^## Unresolved review threads' "$PWD/.agent-pool-context.md" \
    && echo "CONTEXT_HAS_THREADS=1"
} >> "$STUB_CALLS/$name.log"
behave="$(cat "$STUB_BEHAVE/$name" 2>/dev/null || echo ok)"
here() { git rev-parse HEAD; }
review_text() { printf '## Automated review\n1. [suggestion] something\n<!-- pulse-review:v1 head=%s findings=%s -->\n' "$(here)" "$1"; }
# Workers never commit (#30): a resolve that changed files says head=pending, unless the
# behaviour passes a head of its own as $4.
resolve_text() { # fixed noted deferred [head]
  local h="${4:-}"
  [ -n "$h" ] || { if [ "$1" -gt 0 ]; then h=pending; else h="$(here)"; fi; }
  printf '## Automated resolve\nSummary: %s\nFixed: see the diff\n<!-- pulse-resolve:v1 head=%s reviewed=%s fixed=%s noted=%s deferred=%s -->\n' \
    "${SUMMARY:-fix: something}" "$h" "$review_head" "$1" "$2" "$3"; }
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
commit_fix() { echo "fix $RANDOM" >> f.txt; }
trap 'echo "HEAD_AFTER=$(git rev-parse HEAD 2>/dev/null)" >> "$STUB_CALLS/$name.log"' EXIT
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
    resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"; success ;;
  resolve-toolconf-claude)
    commit_fix; mkdir -p .claude; echo '{}' > .claude/settings.json
    resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"; success ;;
  resolve-context)
    commit_fix; echo "worker note" >> .agent-pool-context.md
    resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"; success ;;
  resolve-secret-msg)
    commit_fix
    SUMMARY="fix: something token: 3f9a0c1d2e4b5a6978c0d1e2f3a4b5c6d7e8f901" resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"; success ;;
  resolve-secret-diff)
    echo "GITEA_TOKEN=3f9a0c1d2e4b5a6978c0d1e2f3a4b5c6d7e8f901" >> f.txt
    resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"; success ;;
  resolve-commit)
    # The old worker-side commit #30 removed: the policy denies it, and the controller refuses it.
    commit_fix; git add f.txt; git commit -q -m "fix: a worker's own commit"
    resolve_text 1 $(( ${findings:-1} - 1 )) 0 "$(here)" > "$report"; success ;;
  resolve-oldhead)
    commit_fix; resolve_text 1 $(( ${findings:-1} - 1 )) 0 "$(here)" > "$report"; success ;;
  resolve-credfile)
    commit_fix; echo "API_URL=http://x" > .env; resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"; success ;;
  resolve-nested)
    commit_fix; mkdir -p vendored; git -C vendored init -q; echo x > vendored/a.txt
    resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"; success ;;
  resolve-delete)
    rm -f f.txt; mkdir -p src; echo new > src/new.txt
    resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"; success ;;
  resolve-nosummary)
    commit_fix; printf '## Automated resolve\n<!-- pulse-resolve:v1 head=pending reviewed=%s fixed=1 noted=%s deferred=0 -->\n' \
      "$review_head" $(( ${findings:-1} - 1 )) > "$report"; success ;;
  resolve-pending-nochange)
    resolve_text 0 "${findings:-1}" 0 pending > "$report"; success ;;
  resolve-stealkey)
    commit_fix; mv "$AGENT_POOL_SIGNING_KEY" "$AGENT_POOL_SIGNING_KEY.moved"
    resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"; success ;;
  resolve-lag)
    commit_fix; cat "$STUB_BEHAVE/lag" > "$STUB_GITEA.lag"
    resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"; success ;;
  resolve-gatefile)
    commit_fix; sed -i 's/"just", "gate"/"just", "evil"/' .agent-pool/gates.toml
    resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"; success ;;
  resolve-gatescript)
    commit_fix; printf 'gate:\n\texit 0\n' > justfile
    resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"; success ;;
  resolve-docs)
    mkdir -p docs; echo "note $RANDOM" >> docs/notes.md
    SUMMARY="docs: note" resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"; success ;;
  resolve-plant)
    commit_fix; echo planted > planted.txt; resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"; success ;;
  resolve-gitconfig)
    commit_fix; git config pool.tampered yes; resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"; success ;;
  resolve-miscount) commit_fix; resolve_text 1 "${findings:-1}" 0 > "$report"; success ;;
  resolve-unclaimed) commit_fix; resolve_text 0 "${findings:-1}" 0 > "$report"; success ;;
  resolve-push)
    commit_fix
    git push -q origin "$(git commit-tree "$(git write-tree)" -p HEAD -m sneaky):refs/heads/feature/x" >/dev/null 2>&1
    echo "PUSH_RC=$?" >> "$STUB_CALLS/$name.log"
    resolve_text 1 $(( ${findings:-1} - 1 )) 0 > "$report"; success ;;
  resolve-nonff)
    git checkout -q --detach HEAD~1; commit_fix; resolve_text 1 0 0 "$(here)" > "$report"; success ;;
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

# ---------------------------------------------------------------- stub gate sandbox
# The controller's gate runner always goes through systemd-run and bwrap. These stubs keep the
# suite hermetic: they record their arguments and emulate only what the controller relies on
# (bwrap's --clearenv/--setenv, the /work bind and --chdir, and the --json-status-fd protocol).
# verify-gates.sh runs the same runner against the real bwrap and systemd-run.
cat > "$BIN/stub-systemd-run" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "@CALLS@/scope.log"
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
exec "$@"
SH
cat > "$BIN/stub-bwrap" <<'PY'
#!/usr/bin/env python3
import json, os, signal, subprocess, sys
calls, behave = "@CALLS@", "@BEHAVE@"
args = sys.argv[1:]
open(calls + "/bwrap.log", "a").write("--- call\n" + "".join(f"ARG {x}\n" for x in args))
if os.path.exists(behave + "/sandbox") and open(behave + "/sandbox").read().strip() == "broken":
    sys.exit("bwrap: setting up uid map: Permission denied")
two = {"--ro-bind", "--ro-bind-try", "--bind", "--bind-try", "--dev-bind", "--symlink", "--setenv"}
one = {"--tmpfs", "--dir", "--proc", "--dev", "--chdir", "--json-status-fd", "--unsetenv"}
env, binds, chdir, status, clear, i = {}, {}, "/", None, False, 0
while args[i] != "--":
    if args[i] in two:
        if args[i] == "--setenv":
            env[args[i + 1]] = args[i + 2]
        elif args[i] in ("--bind", "--ro-bind"):
            binds[args[i + 2]] = args[i + 1]
        i += 3
    elif args[i] in one:
        if args[i] == "--chdir":
            chdir = args[i + 1]
        elif args[i] == "--json-status-fd":
            status = int(args[i + 1])
        i += 2
    else:
        clear = clear or args[i] == "--clearenv"
        i += 1
if not clear:
    env = {**os.environ, **env}
emit = lambda doc: os.write(status, (json.dumps(doc) + "\n").encode())
try:
    child = subprocess.Popen(args[i + 1:], env=env, cwd=chdir.replace("/work", binds["/work"], 1), start_new_session=True)
except OSError as error:
    emit({"child-pid": 0})
    sys.exit(f"bwrap: execvp {args[i + 1]}: {error.strerror}")
# Stand-in for --die-with-parent: whoever stops this stub stops the gate with it.
signal.signal(signal.SIGTERM, lambda *_: (os.killpg(child.pid, signal.SIGKILL), sys.exit(143)))
emit({"child-pid": child.pid})
rc = child.wait()
rc = rc if rc >= 0 else 128 - rc
emit({"exit-code": rc})
sys.exit(rc)
PY
sed -i "s|@CALLS@|$TMP/calls|; s|@BEHAVE@|$TMP/behave|" "$BIN/stub-systemd-run" "$BIN/stub-bwrap"
chmod +x "$BIN/stub-systemd-run" "$BIN/stub-bwrap"
# The only gate runner the fixture manifest names. The sandbox env is cleared, so every path it
# needs is baked in here.
mkdir -p "$TMP/toolchain/bin"
cat > "$TMP/toolchain/bin/just" <<'SH'
#!/bin/sh
T="@TMP@"
echo "$*" >> "$T/calls/gate-ran"
{ echo "--- gate $*"; env | sort; echo "PWD=$PWD"; echo "LS=$(ls -A | tr '\n' ' ')"
  [ -f payload.txt ] && echo "PAYLOAD=$(cat payload.txt)"; } >> "$T/calls/gate-seen"
[ "$1" = evil ] && : > "$T/calls/gate-evil"
case "$(cat "$T/behave/gate" 2>/dev/null || echo pass)" in
  pass)  echo "all green" ;;
  fail)  echo "3 tests red"; echo "FAILED: test_secret_detail" >&2; exit 1 ;;
  sleep) sleep 30 & echo $! >> "$T/stub-pids"; wait $! ;;
  steal)
    export STUB_GITEA="$T/gitea.json" STUB_ORIGIN="$T/origin.git" AGENT_POOL_STATE="$T/state"
    attempt="$(python3 "@CLAIMREC@" show --repo owner/repo --pr 7 | python3 -c 'import json,sys; print(json.load(sys.stdin)["attempt_id"])')"
    AGENT_POOL_NOW=$(( $(date +%s) + 100000 )) python3 "@CLAIMREC@" requeue --repo owner/repo --pr 7 \
      --attempt "$attempt" --adapter "$T/common/gitea-pr.py" >/dev/null
    python3 "@CLAIMREC@" claim --repo owner/repo --pr 7 --worker thief --provider grok \
      -- python3 "$T/common/gitea-pr.py" label --repo owner/repo --pr 7 --remove agent:ready --add agent:claimed >/dev/null
    sleep 300 & echo $! > "$T/calls/gate-sleep.pid"; echo $! >> "$T/stub-pids"; wait $! ;;
esac
SH
sed -i "s|@TMP@|$TMP|; s|@CLAIMREC@|$CLAIMREC|g" "$TMP/toolchain/bin/just"
chmod +x "$TMP/toolchain/bin/just"

# ---------------------------------------------------------------- harness
export AGENT_POOL_MAIN="$TMP/main" AGENT_POOL_REPO="$R" AGENT_POOL_STATE="$TMP/state"
export AGENT_POOL_WORKTREES="$TMP/wt" AGENT_POOL_ADAPTER="$TMP/common/gitea-pr.py"
export AGENT_POOL_MARKER="$TMP/common/marker.py" AGENT_POOL_WORKER_ID=test-worker AGENT_POOL_WATCH_SECS=1
export ANTHROPIC_API_KEY=stale-key-for-test PR_LOOP_SKIP_PATTERN=""
export AGENT_POOL_GATE_SANDBOX="$BIN/stub-bwrap" AGENT_POOL_GATE_SCOPE="$BIN/stub-systemd-run"
export AGENT_POOL_GATE_RO_BINDS="$TMP/toolchain" AGENT_POOL_GATES_DIR="$TMP/gates-override"
unset PROVIDER_ORDER AGY_AUTO_APPROVE

reset() { # labels-json [assignees-json] [comments-json] [head-ref] [base-ref]
  rm -rf "$TMP/state" "$TMP/calls"/* "$TMP/behave"/* "$STUB_GITEA.writes" "$STUB_GITEA.race" "$STUB_GITEA.lag" \
    "$STUB_GITEA.faildone"
  git --git-dir "$ORIGIN" update-ref refs/heads/feature/x "$SHA"
  git --git-dir "$ORIGIN" update-ref "refs/heads/$ODD_REF" "$SHA"
  git --git-dir "$ORIGIN" update-ref refs/heads/feature/gatepr "$GATEPR_SHA"
  git --git-dir "$ORIGIN" update-ref refs/heads/feature/attr "$ATTR_SHA"
  python3 - "$STUB_GITEA" "$1" "${2:-[]}" "${3:-[]}" "${4:-feature/x}" "$SHA" "${5:-master}" <<'PY'
import json, sys
path, labels, assignees, comments, ref, sha, base = sys.argv[1:]
json.dump({"prs": {"7": {"head_ref": ref, "head_sha": sha, "base_ref": base, "labels": json.loads(labels),
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
expect "the context file includes unresolved review threads for claude's attempt" "$(calls claude)" "CONTEXT_HAS_THREADS=1"
expect "and for cursor's fallback attempt too" "$(calls cursor-agent)" "CONTEXT_HAS_THREADS=1"
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
expect_not "the controller pushed its own commit of the worker's edits" "$newhead" "$SHA"
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
expect "a worker that moves its own HEAD is never pushed" "$(origin_head)" "$SHA"
expect "it goes to agent:needs-human" "$(labels)" "agent:needs-human"
expect "with a comment saying why" "$(comments)" "workers never commit"
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
pushed_paths() { git --git-dir "$ORIGIN" show --name-only --format= "refs/heads/${1:-feature/x}"; }
for tc in cursor claude; do
  reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
  behave claude "resolve-toolconf-$tc"
  tick
  expect_not "S3: the worker's real fix is pushed (.$tc/)" "$(origin_head)" "$SHA"
  expect "S3: as the controller's commit of f.txt (.$tc/)" "$(pushed_paths)" "f.txt"
  expect_not "S3: tool configuration under .$tc/ never reaches the commit" "$(pushed_paths)" ".$tc/"
  expect "S3: and the resolve is done (.$tc/)" "$(labels)" "agent:done"
done
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-context
tick
expect_not "r4#5: a worker's edit to the context file never reaches the commit" "$(pushed_paths)" ".agent-pool-context.md"
expect "r4#5: while its real fix does" "$(pushed_paths)" "f.txt"
for leak in msg diff; do
  reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
  behave claude "resolve-secret-$leak"
  tick
  expect "r4#2: a credential in the commit $leak is never pushed" "$(origin_head)" "$SHA"
  expect "r4#2: and goes to needs-human ($leak)" "$(labels)" "agent:needs-human"
  expect "r4#2: with the reason ($leak)" "$(comments)" "a credential or token-shaped string"
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
echo "controller gates: pinned on the base branch, run after the worker in a sandbox, before any push"
gate_ran() { cat "$TMP/calls/gate-ran" 2>/dev/null || echo none; }
gate_seen() { cat "$TMP/calls/gate-seen" 2>/dev/null; }
receipt() { cat "$TMP/state/gates/owner_repo__7__"*.json 2>/dev/null || echo none; }
last_comment() { comments | python3 -c 'import json,sys; c=json.load(sys.stdin); print(c[-1]["body"] if c else "")'; }
marker_for() { printf '[{"id":1,"user":"bot","created_at":"","body":"## Automated review\\n1. x\\n<!-- pulse-review:v1 head=%s findings=1 -->"}]' "$1"; }
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-fix
GITEA_TOKEN=gitea-token-for-test SSH_AUTH_SOCK="$TMP/agent.sock" tick
newhead="$(origin_head)"
expect_not "a green gate lets the controller push" "$newhead" "$SHA"
expect "and the resolve is done" "$(labels)" "agent:done"
expect "the base manifest's gate ran" "$(gate_ran)" "gate"
expect "the gate ran in a checkout of the tracked files only, with no .git" "$(gate_seen | grep '^LS=')" "LS=.agent-pool f.txt justfile "
expect_not "the gate never sees the Gitea token" "$(gate_seen)" "GITEA_TOKEN"
expect_not "nor the ssh agent" "$(gate_seen)" "SSH_AUTH_SOCK"
expect_not "nor a provider key" "$(gate_seen)" "ANTHROPIC_API_KEY"
expect "the gate has a sandbox home" "$(gate_seen)" "HOME=/home/gate"
expect "the gate runs in a systemd scope with cgroup limits" "$(cat "$TMP/calls/scope.log")" "-p MemoryMax=4G -p MemorySwapMax=0 -p TasksMax=512"
expect "which never expands \$VARs in the gate's argv" "$(cat "$TMP/calls/scope.log")" "--expand-environment=no"
expect "inside bwrap with every namespace unshared" "$(cat "$TMP/calls/bwrap.log")" "ARG --unshare-all"
expect "a cleared env" "$(cat "$TMP/calls/bwrap.log")" "ARG --clearenv"
expect "and a tmpfs /home" "$(tr '\n' ' ' < "$TMP/calls/bwrap.log")" "ARG --tmpfs ARG /home"
expect "a receipt keyed by the attempt records the pass" "$(receipt)" '"result": "pass"'
expect "bound to the pushed head" "$(receipt)" "\"head\": \"$newhead\""
expect "naming the base manifest's blob" "$(receipt)" "\"blob\": \"$(git --git-dir "$ORIGIN" rev-parse master:.agent-pool/gates.toml)\""
expect "the receipt is read-only" "$(stat -c %a "$TMP/state/gates/owner_repo__7__"*.json)" "444"
expect "with a by-head copy" "$(ls "$TMP/state/gates/by-head")" "owner_repo__7__$newhead.json"
body="$(last_comment)"
expect "the posted report carries the controller's gate section" "$body" "### Gates (run by the pool controller)"
expect "with the gate marker before the resolve marker" "${body%%pulse-resolve:v1*}" "agent-pool-gates:v1 head=$newhead manifest="
expect "and the resolve marker still last" "$(printf '%s\n' "$body" | sed '/^$/d' | tail -1)" "pulse-resolve:v1 head=$newhead"

reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-fix; behave gate fail
tick
expect "a red gate is never pushed" "$(origin_head)" "$SHA"
expect "it goes to needs-human" "$(labels)" "agent:needs-human"
expect "the comment names the gate and its exit" "$(comments)" "gate 'unit' exited 1"
expect "and says nothing was pushed" "$(comments)" "nothing was pushed"
expect_not "no resolve report is posted" "$(comments)" "pulse-resolve"
expect_not "the gate's output is never posted" "$(comments)" "FAILED: test_secret_detail"
expect "both its fds land in one host log, in order" "$(tr '\n' '|' < "$(ls "$TMP/state/runs/gate-7-"*-unit.log)")" "3 tests red|FAILED: test_secret_detail|"
expect "a red gate costs the provider no cooldown" "$(cooldown_doc claude)" "none"
expect "the receipt records the failure" "$(receipt)" '"result": "gate-fail"'

reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-fix; behave gate sleep
tick
expect "a gate past its timeout is never pushed" "$(origin_head)" "$SHA"
expect "it goes to needs-human" "$(labels)" "agent:needs-human"
expect "saying it timed out" "$(comments)" "gate 'unit' timed out after 4s"
expect "the receipt records the timeout" "$(receipt)" '"result": "gate-timeout"'

reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-fix
AGENT_POOL_GATE_SANDBOX=/nonexistent/bwrap tick
expect "no sandbox: nothing is pushed" "$(origin_head)" "$SHA"
expect "the job is requeued" "$(labels)" "agent:ready"
expect "as a setup fault of the gates, not the provider" "$(cat "$TMP/out.txt")" "SETUP FAULT [gates]: bwrap is unavailable"
expect "the tick exits 2" "$TICK_RC" "2"
expect "the provider is not cooled down" "$(cooldown_doc claude)" "none"
expect_not "no comment is posted" "$(comments)" "pool stopped"
expect_not "and no report" "$(comments)" "pulse-resolve"
expect "no gate ran" "$(gate_ran)" "none"
tick
expect "while the fault stands, resolve jobs are not claimed" "$(cat "$TMP/out.txt")" "resolve jobs are paused"
expect "so the provider is not run again" "$(ncalls claude)" "1"
python3 -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["prs"]["7"]["comments"]=[]; json.dump(s, open(p,"w"))' "$STUB_GITEA"
behave claude ok
tick
expect "but reviews still run" "$(comments)" "pulse-review:v1 head=$SHA"

reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-fix; behave sandbox broken
tick
expect "a sandbox that cannot start pushes nothing" "$(origin_head)" "$SHA"
expect "and is a gates setup fault" "$(cat "$TMP/out.txt")" "SETUP FAULT [gates]: gate 'unit': the sandbox did not start"
expect "the job is requeued" "$(labels)" "agent:ready"
rm -f "$TMP/state/faults/gates.json" "$TMP/behave/sandbox"
AGENT_POOL_GATE_RO_BINDS="$HOME" tick
expect "a toolchain bind of \$HOME itself is refused" "$(cat "$TMP/out.txt")" "is \$HOME or a parent of it"

for change in gatefile:.agent-pool/gates.toml gatescript:justfile; do
  reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
  behave claude "resolve-${change%%:*}"
  tick
  expect "a worker change to ${change#*:} is never pushed" "$(origin_head)" "$SHA"
  expect "it goes to needs-human (${change#*:})" "$(labels)" "agent:needs-human"
  expect "naming the protected path (${change#*:})" "$(comments)" "change gate-defining files (${change#*:})"
  expect "and no gate ran (${change#*:})" "$(gate_ran)" "none"
done

reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-docs
tick
expect "a docs-only fix no gate covers is pushed" "$(git --git-dir "$ORIGIN" log -1 --format=%s feature/x)" "docs: note"
expect "and done" "$(labels)" "agent:done"
expect "without running a gate" "$(gate_ran)" "none"
expect "the report says no gate applies" "$(comments)" "No gate applies to the changed paths"
expect "the receipt says none-needed" "$(receipt)" '"result": "none-needed"'

reset '["agent:ready"]' '[]' "$REVIEW_MARKER" feature/x bare
behave claude resolve-fix
tick
expect "a base with no manifest: a code fix is never pushed" "$(origin_head)" "$SHA"
expect "it goes to needs-human" "$(labels)" "agent:needs-human"
expect "saying there is no manifest" "$(comments)" "has no gate manifest"
reset '["agent:ready"]' '[]' "$REVIEW_MARKER" feature/x bare
behave claude resolve-docs
tick
expect "a base with no manifest: a docs-only fix is pushed" "$(git --git-dir "$ORIGIN" log -1 --format=%s feature/x)" "docs: note"

reset '["agent:ready"]' '[]' "$(marker_for "$GATEPR_SHA")" feature/gatepr
behave claude resolve-fix
tick
expect "a PR that rewrites its own manifest is gated by its base's" "$(gate_ran)" "gate"
expect "the PR's gate never runs" "$([ -e "$TMP/calls/gate-evil" ] && echo ran || echo absent)" "absent"
expect "and the fix is pushed" "$(git --git-dir "$ORIGIN" log -1 --format=%s feature/gatepr)" "fix: something"

mkdir -p "$TMP/gates-override"
printf 'version = 1\n[[gate]]\nname = "pinned"\nargv = ["just", "override"]\npaths = ["**"]\n' > "$TMP/gates-override/owner__repo.toml"
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-fix
tick
rm -rf "$TMP/gates-override"
expect "a controller-owned override wins over the base manifest" "$(gate_ran)" "override"
expect "and the receipt says so" "$(receipt)" '"source": "override"'

reset '["agent:ready"]' '[]' "$(marker_for "$ATTR_SHA")" feature/attr
printf '[filter "evil"]\n\tsmudge = sed s/ORIGINAL/PWNED-GLOBAL/\n\tclean = cat\n' > "$HOME/.gitconfig"
printf '#!/bin/sh\ncase "$PWD" in *gate-work*) : > "%s/calls/hook-ran" ;; esac\n' "$TMP" > "$TMP/main/.git/hooks/post-checkout"
chmod +x "$TMP/main/.git/hooks/post-checkout"
behave claude resolve-plant
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=filter.evil.smudge GIT_CONFIG_VALUE_0="sed s/ORIGINAL/PWNED-ENV/" tick
rm -f "$HOME/.gitconfig" "$TMP/main/.git/hooks/post-checkout"
expect "the gate checkout honours no global-config filter" "$(gate_seen)" "PAYLOAD=ORIGINAL"
expect_not "nor one from the tick's GIT_CONFIG_* env" "$(gate_seen)" "PWNED"
expect "only committed content reaches the gate" "$(gate_seen | grep '^LS=')" "payload.txt"
expect "#30: a new file the worker left is part of the controller's commit, so the gate sees it" "$(gate_seen | grep '^LS=')" "planted.txt"
expect_not "never the pool's own context file" "$(gate_seen | grep '^LS=')" ".agent-pool-context.md"
expect_not "#30: the worktree is checked out without the tick's filters, so payload.txt is no change" "$(pushed_paths feature/attr)" "payload.txt"
expect "no hook in the main clone ran on the gate checkout" "$([ -e "$TMP/calls/hook-ran" ] && echo ran || echo none)" "none"
expect "and the fix is pushed" "$(git --git-dir "$ORIGIN" log -1 --format=%s feature/attr)" "fix: something"

reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-gitconfig
tick
git -C "$TMP/main" config --unset pool.tampered
expect "a worker that rewrites the main clone's git config gets nothing pushed" "$(origin_head)" "$SHA"
expect "it is an infra fault" "$(cat "$TMP/out.txt")" "SETUP FAULT [gates]: the main clone's git config changed"
expect "and the job is requeued" "$(labels)" "agent:ready"

reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-fix; behave gate steal
t0=$(date +%s); tick; took=$(( $(date +%s) - t0 ))
expect "a claim superseded during the gate run is noticed" "$(cat "$TMP/out.txt")" "superseded before its work was published"
expect "and stops the gate long before it finishes" "$([ "$took" -lt 60 ] && echo fast || echo "slow ${took}s")" "fast"
gs="$(cat "$TMP/calls/gate-sleep.pid" 2>/dev/null)"
expect "the gate's processes are killed" "$(kill -0 "$gs" 2>/dev/null && echo alive || echo dead)" "dead"
expect "nothing is pushed" "$(origin_head)" "$SHA"
expect_not "nothing is posted" "$(comments)" "pulse-resolve"
expect "the new holder's claim stands" "$(record)" "\"worker_id\": \"thief\""

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
echo "commit rules (#30): no worker may stage or commit, whatever the job or provider"
claude_allows() { calls claude | sed -n '/^ARG --allowedTools$/,/^ARG --disallowedTools$/p'; }
claude_denies() { calls claude | sed -n '/^ARG --disallowedTools$/,/^[^A]/p'; }
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave cursor-agent resolve-fix
PROVIDER_ORDER=cursor tick
expect_not "#30: cursor resolve cli.json allows no git commit" "$(calls cursor-agent | grep '^CURSOR_ALLOW')" "git commit"
expect_not "#30: cursor resolve cli.json allows no git add" "$(calls cursor-agent | grep '^CURSOR_ALLOW')" "git add"
for rule in 'git add' 'git commit' 'git commit-tree' 'git push' 'git push --force' 'git stash'; do
  expect "#30: cursor resolve cli.json denies $rule" "$(calls cursor-agent)" "CURSOR_DENY Shell($rule)"
done
expect_not "cursor resolve cli.json allows no push" "$(calls cursor-agent | grep '^CURSOR_ALLOW')" "git push"
expect "cursor's edits reach the branch as the controller's commit" "$(git --git-dir "$ORIGIN" log -1 --format=%s feature/x)" "fix: something"
expect "#30: carrying cursor as the provider" "$(git --git-dir "$ORIGIN" log -1 --format='%(trailers:key=Agent-Pool-Provider,valueonly)' feature/x)" "cursor"
expect "and the resolve is done" "$(labels)" "agent:done"
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-fix
tick
expect_not "#30: claude resolve allows no git commit" "$(claude_allows)" "git commit"
expect_not "#30: claude resolve allows no git add" "$(claude_allows)" "git add"
expect_not "claude resolve allows no push" "$(claude_allows)" "git push"
for rule in 'git add*' 'git commit*' 'git push*' 'git push --force*' 'git stash*'; do
  expect "#30: claude resolve denies $rule" "$(claude_denies)" "ARG Bash($rule)"
done
expect "claude's edits reach the branch as the controller's commit" "$(git --git-dir "$ORIGIN" log -1 --format=%s feature/x)" "fix: something"
reset '["agent:ready"]'
behave cursor-agent ok
PROVIDER_ORDER=cursor tick
expect_not "cursor review cli.json allows no git commit" "$(calls cursor-agent | grep '^CURSOR_ALLOW')" "git commit"
expect "cursor review cli.json denies git commit" "$(calls cursor-agent)" "CURSOR_DENY Shell(git commit)"
reset '["agent:ready"]'
behave claude ok
tick
expect_not "claude review allows no git commit" "$(claude_allows)" "git commit"
expect "claude review denies git commit" "$(claude_denies)" "ARG Bash(git commit*)"

echo
echo "controller commits (#30): one SSH-signed commit per run, made by the controller, with trailers"
trailer() { git --git-dir "$ORIGIN" log -1 --format="%(trailers:key=$1,valueonly)" "refs/heads/${2:-feature/x}"; }
verify_sig() { git --git-dir "$ORIGIN" -c gpg.ssh.allowedSignersFile="$TMP/signing/allowed_signers" verify-commit "$1" >/dev/null 2>&1 && echo good || echo bad; }
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-fix
tick
newhead="$(origin_head)"
attempt_id="$(basename "$(ls "$TMP/state/gates/owner_repo__7__"*.json)" .json)"; attempt_id="${attempt_id##*__}"
expect_not "#30: a resolve run is pushed" "$newhead" "$SHA"
expect "#30: as exactly one commit on top of the reviewed head" "$(git --git-dir "$ORIGIN" rev-list --count "$SHA..$newhead")" "1"
expect "#30: whose only parent is the reviewed head" "$(git --git-dir "$ORIGIN" rev-parse "$newhead^@")" "$SHA"
expect "#30: the worker never moved its HEAD (it made no commit)" "$(calls claude | grep '^HEAD_AFTER=')" "HEAD_AFTER=$SHA"
expect "#30: the commit is SSH-signed" "$(git --git-dir "$ORIGIN" cat-file commit "$newhead")" "gpgsig -----BEGIN SSH SIGNATURE-----"
expect "#30: by the controller's key (git verify-commit)" "$(verify_sig "$newhead")" "good"
expect "#30: git reports a good signature" "$(git --git-dir "$ORIGIN" -c gpg.ssh.allowedSignersFile="$TMP/signing/allowed_signers" log -1 --format=%G? "$newhead")" "G"
expect "#30: committed as the controller, not the worker's git identity" "$(git --git-dir "$ORIGIN" log -1 --format='%an <%ae> / %cn <%ce>' "$newhead")" "agent-pool <agent-pool@localhost> / agent-pool <agent-pool@localhost>"
expect "#30: the subject is the report's Summary line" "$(git --git-dir "$ORIGIN" log -1 --format=%s "$newhead")" "fix: something"
expect "#30: trailer Agent-Pool-Provider" "$(trailer Agent-Pool-Provider)" "claude"
expect "#30: trailer Agent-Pool-Ability" "$(trailer Agent-Pool-Ability)" "resolve"
expect "#30: trailer Agent-Pool-Worker" "$(trailer Agent-Pool-Worker)" "test-worker"
expect "#30: trailer Agent-Pool-Attempt names the attempt the gate receipt is bound to" "$(trailer Agent-Pool-Attempt)" "$attempt_id"
expect "#30: trailer Agent-Pool-Model" "$(trailer Agent-Pool-Model)" "opus"
expect "#30: all five trailers, each once" "$(git --git-dir "$ORIGIN" log -1 --format='%(trailers:only,unfold)' "$newhead" | grep -c '^Agent-Pool-')" "5"
expect "#30: the posted marker carries the stamped head" "$(comments)" "pulse-resolve:v1 head=$newhead reviewed=$SHA"
expect_not "#30: never head=pending" "$(comments)" "head=pending"
expect "#30: the resolve is done" "$(labels)" "agent:done"
expect "#30: the commit is logged as signed" "$(cat "$TMP/out.txt")" "committed $SHA..$newhead for claude (resolve, 1 path(s), signed)"
expect "#30: the controller's private index is gone" "$(ls "$TMP/state/runs" | grep -c '^index-')" "0"
expect_not "#30: no key material reaches the log" "$(cat "$TMP/state/pool.log" "$TMP/out.txt")" "$(sed -n 2p "$TMP/signing/key")"
expect_not "#30: nor the public key" "$(cat "$TMP/state/pool.log" "$TMP/out.txt")" "$(cut -d' ' -f2 "$TMP/signing/key.pub")"

reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-delete
tick
newhead="$(origin_head)"
expect "#30: a deletion and a new file in a new directory are both committed" "$(git --git-dir "$ORIGIN" show --name-status --format= "$newhead" | tr '\t\n' ' ')" "D f.txt A src/new.txt"
expect "#30: and signed" "$(verify_sig "$newhead")" "good"
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-nosummary
tick
expect "#30: with no Summary line the controller writes the subject" "$(git --git-dir "$ORIGIN" log -1 --format=%s feature/x)" "chore(resolve): automated resolve for #7"
expect "#30: and still all five trailers" "$(git --git-dir "$ORIGIN" log -1 --format='%(trailers:only,unfold)' feature/x | grep -c '^Agent-Pool-')" "5"
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-pending-nochange
tick
expect "#30: head=pending with no change is stamped with the PR head, nothing committed" "$(comments)" "pulse-resolve:v1 head=$SHA reviewed=$SHA"
expect "#30: and nothing is pushed" "$(origin_head)" "$SHA"
expect "#30: it is done" "$(labels)" "agent:done"

reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-commit
tick
expect "#30: a worker that commits itself is never pushed" "$(origin_head)" "$SHA"
expect "#30: it goes to needs-human" "$(labels)" "agent:needs-human"
expect "#30: saying workers never commit" "$(comments)" "workers never commit"
expect_not "#30: no resolve report is posted" "$(comments)" "pulse-resolve"
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-oldhead
tick
expect "#30: changes under a marker that says head=<sha>, not pending, are never pushed" "$(origin_head)" "$SHA"
expect "#30: and the reason is given" "$(comments)" "not head=pending"
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-credfile
tick
expect "#30: a credential-named file is never committed or pushed" "$(origin_head)" "$SHA"
expect "#30: it goes to needs-human naming the file" "$(comments)" "credential-named files (.env)"
expect "#30: and no gate ran" "$(gate_ran)" "none"
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-nested
tick
expect "#30: a nested repository is never committed (no gitlink sneaks in)" "$(origin_head)" "$SHA"
expect "#30: and the reason is given" "$(comments)" "nested git repository (vendored/)"

echo "  (the signing key is required: no key is a setup fault, never an unsigned commit)"
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-fix
AGENT_POOL_SIGNING_KEY= tick
expect "#30: no signing key: a setup fault [signing]" "$(cat "$TMP/out.txt")" "SETUP FAULT [signing]: no commit signing key is configured"
expect "#30: the tick exits 2" "$TICK_RC" "2"
expect "#30: resolve jobs are not claimed" "$(cat "$TMP/out.txt")" "resolve jobs are paused: the controller cannot sign commits"
expect "#30: so no provider ran" "$(ncalls claude)" "0"
expect "#30: nothing is pushed" "$(origin_head)" "$SHA"
expect "#30: the PR stays queued" "$(labels)" "agent:ready"
expect "#30: the fault is recorded" "$(cat "$TMP/state/faults/signing.json" 2>/dev/null)" "no commit signing key"
AGENT_POOL_SIGNING_KEY="$TMP/signing/no-such-key" tick
expect "#30: a missing key file is a setup fault" "$(cat "$TMP/out.txt")" "SETUP FAULT [signing]: the signing key $TMP/signing/no-such-key is missing or unreadable"
AGENT_POOL_SIGNING_KEY="signing/key" tick
expect "#30: a relative key path is a setup fault" "$(cat "$TMP/out.txt")" "is not an absolute path"
ssh-keygen -q -t ed25519 -N 'a-passphrase-for-test' -f "$TMP/signing/locked" </dev/null >/dev/null
AGENT_POOL_SIGNING_KEY="$TMP/signing/locked" tick
expect "#30: a passphrase-protected key is a setup fault" "$(cat "$TMP/out.txt")" "is not a passphrase-less SSH private key"
cp "$TMP/signing/key" "$TMP/signing/loose"; chmod 644 "$TMP/signing/loose"
AGENT_POOL_SIGNING_KEY="$TMP/signing/loose" tick
expect "#30: a key others can read is a setup fault" "$(cat "$TMP/out.txt")" "SETUP FAULT [signing]: the signing key $TMP/signing/loose is not"
expect "#30: still nothing ran" "$(ncalls claude)" "0"
python3 -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["prs"]["7"]["comments"]=[]; json.dump(s, open(p,"w"))' "$STUB_GITEA"
behave claude ok
AGENT_POOL_SIGNING_KEY= tick
expect "#30: reviews need no key and still run" "$(comments)" "pulse-review:v1 head=$SHA"
reset '["agent:ready"]' '[]' "$REVIEW_MARKER"
behave claude resolve-stealkey
tick
mv "$TMP/signing/key.moved" "$TMP/signing/key"
expect "#30: a key gone by commit time: nothing is committed or pushed" "$(origin_head)" "$SHA"
expect "#30: it is a setup fault [signing]" "$(cat "$TMP/out.txt")" "SETUP FAULT [signing]: the signing key $TMP/signing/key is missing or unreadable"
expect "#30: the job is requeued, not needs-human" "$(labels)" "agent:ready"
expect "#30: and the provider is not cooled down" "$(cooldown_doc claude)" "none"
expect_not "#30: no unsigned commit was pushed or posted" "$(comments)" "pulse-resolve"

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
expect_not "#30: the generic resolve prompt no longer tells a worker to stage" "$(cat "$REAL_COMMON/prompts/resolve.generic.txt")" "git add path/"
expect_not "#30: nor to commit" "$(cat "$REAL_COMMON/prompts/resolve.generic.txt")" 'git commit -m "'
expect "#30: it says the controller commits" "$(cat "$REAL_COMMON/prompts/resolve.generic.txt")" "Leave your changes in the worktree, uncommitted"
expect "#30: it asks for head=pending" "$(cat "$REAL_COMMON/prompts/resolve.generic.txt")" "head=<the word pending if you changed any file"
expect "#30: and for the Summary line the commit subject comes from" "$(cat "$REAL_COMMON/prompts/resolve.generic.txt")" '"Summary: "'
expect "G5: the resolve prompt has the final-response fallback" "$(cat "$REAL_COMMON/prompts/resolve.generic.txt")" "If you cannot write files, make the complete report your final response instead"
expect "L3: the resolve count covers only the review's numbered findings" "$(cat "$REAL_COMMON/prompts/resolve.generic.txt")" "thread replies are never counted"
expect "L3: thread replies are listed separately" "$(cat "$REAL_COMMON/prompts/resolve.generic.txt")" "list Thread replies"
expect_not "L3: inline threads are no longer counted as findings" "$(cat "$REAL_COMMON/prompts/resolve.generic.txt")" "Treat each as one finding"
expect_not "no generic or agy prompt uses an em or en dash" "$(cat "$REAL_COMMON/prompts/"*.generic.txt "$REAL_COMMON/prompts/review.agy.txt")" "—"
expect_not "the generic prompts use no Claude-only skill" "$(cat "$REAL_COMMON/prompts/review.generic.txt" "$REAL_COMMON/prompts/resolve.generic.txt")" "mattpocock-skills"
expect_not "no prompt tells a worker to post a comment" "$(cat "$REAL_COMMON/prompts/review.generic.txt" "$REAL_COMMON/prompts/resolve.generic.txt")" "__ADAPTER__ comment "
expect_not "no prompt tells a worker to push" "$(cat "$REAL_COMMON/prompts/review.generic.txt" "$REAL_COMMON/prompts/resolve.generic.txt")" "git push origin"
expect_not "no review/resolve prompt invokes the adapter directly for comments or threads (controller-gates.md Section 4: dropped)" \
  "$(cat "$REAL_COMMON/prompts/review.generic.txt" "$REAL_COMMON/prompts/resolve.generic.txt")" "__ADAPTER__ comments"
expect_not "nor for threads" "$(cat "$REAL_COMMON/prompts/resolve.generic.txt")" "__ADAPTER__ threads"
expect "the review prompt reads comments from the controller's context file instead" "$(cat "$REAL_COMMON/prompts/review.generic.txt")" "__CONTEXT__'s \"PR comments (JSON)\" section"
expect "the resolve prompt reads findings from the context file" "$(cat "$REAL_COMMON/prompts/resolve.generic.txt")" "read __CONTEXT__"
expect "and unresolved threads from its own section" "$(cat "$REAL_COMMON/prompts/resolve.generic.txt")" "\"Unresolved review threads (JSON)\" section"
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
