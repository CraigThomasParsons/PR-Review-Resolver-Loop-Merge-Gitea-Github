#!/usr/bin/env bash
# Offline cases for pr-update.sh (auto-update open PRs after a merge to develop).
#
# A local bare "origin", a stub Gitea adapter keeping labels and comments in JSON, a stub
# conflict resolver, and gates.py with only `run` stubbed (load/changes/select/protected/docs-only
# are the real ones): no network, no provider, no sandbox, no real state.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_GATES="$ROOT/../../agent-pool/scripts/gates.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
git config --global init.defaultBranch develop
git config --global user.name t; git config --global user.email t@example.invalid
ORIGIN="$TMP/origin.git"; MAIN="$TMP/main"

# ---------------------------------------------------------------- stub pool root (gates.py)
POOL="$TMP/pool"; mkdir -p "$POOL/agent-pool/scripts"
cat > "$POOL/agent-pool/scripts/gates.py" <<PY
import json, os, subprocess, sys
if sys.argv[1] != "run":
    sys.exit(subprocess.run([sys.executable, "$REAL_GATES"] + sys.argv[1:]).returncode)
a = sys.argv[2:]
arg = lambda n: a[a.index(n) + 1] if n in a else None
open("$TMP/gate-calls", "a").write("run " + open(arg("--select")).read().strip() + " in " + " ".join(sorted(os.listdir(arg("--gate-dir")))) + "\n")
behave = os.environ.get("GATE_BEHAVE", "pass")
print(json.dumps({"result": behave, "reason": "" if behave == "pass" else "stub says " + behave, "gates": []}))
PY

# The conflict resolver's own helpers are the real ones.
for f in policy.py classify.py cooldown.py poolstate.py; do
  ln -s "$(cd -- "$(dirname -- "$REAL_GATES")" && pwd)/$f" "$POOL/agent-pool/scripts/$f"
done

# ---------------------------------------------------------------- stub adapter
COMMON="$TMP/common"; mkdir -p "$COMMON"
cp "$ROOT/pr-update.sh" "$COMMON/pr-update.sh"
cat > "$COMMON/gitea-pr.py" <<'PY'
import json, os, subprocess, sys
path = os.environ["STUB_GITEA"]; st = json.load(open(path))
a = sys.argv[1:]; arg = lambda n: a[a.index(n) + 1] if n in a else None
def save(): json.dump(st, open(path, "w"), indent=1)
def head(p):
    return subprocess.run(["git", "--git-dir", os.environ["STUB_ORIGIN"], "rev-parse", "refs/heads/" + p["head_ref"]],
                          capture_output=True, text=True).stdout.strip()
if a[0] == "list":
    print(json.dumps([{"number": int(n), "title": "t", "draft": p.get("draft", False), "head_sha": head(p),
        "head_ref": p["head_ref"], "base_ref": p.get("base_ref", "develop"), "author": "h", "is_bot": False,
        "labels": p["labels"], "url": ""} for n, p in st["prs"].items()]))
elif a[0] == "labels":
    print(json.dumps(st["prs"][arg("--pr")]["labels"]))
elif a[0] == "label":
    p = st["prs"][arg("--pr")]
    rm = [x for x in (arg("--remove") or "").split(",") if x]
    p["labels"] = [l for l in p["labels"] if l not in rm]
    for x in (arg("--add") or "").split(","):
        if x and x not in p["labels"]: p["labels"].append(x)
    save(); open(path + ".writes", "a").write(f"label {arg('--pr')} -{arg('--remove')} +{arg('--add')}\n")
elif a[0] == "comment":
    st["prs"][arg("--pr")].setdefault("comments", []).append(open(arg("--body-file")).read())
    save(); open(path + ".writes", "a").write(f"comment {arg('--pr')}\n")
elif a[0] == "head":
    print(head(st["prs"][arg("--pr")]))
PY
export STUB_GITEA="$TMP/gitea.json" STUB_ORIGIN="$ORIGIN"

# ---------------------------------------------------------------- stub resolver
cat > "$TMP/resolver.sh" <<'SH'
#!/usr/bin/env bash
# Takes "ours" for every conflict region; RESOLVER_BEHAVE changes what it does.
echo "resolver pr=$PR_UPDATE_PR files=$(tr '\0' ' ' < "$PR_UPDATE_CONFLICTS")" >> "$RESOLVER_CALLS"
case "${RESOLVER_BEHAVE:-ours}" in
  fail) exit 1 ;;
  markers) exit 0 ;;
  stray) echo stray > stray.txt ;;
esac
while IFS= read -r -d '' f; do
  awk '/^<<<<<<< /{keep=1; next} /^=======$/{keep=0; next} /^>>>>>>> /{keep=1; next} {if (keep!=0) print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done < "$PR_UPDATE_CONFLICTS"
SH
chmod +x "$TMP/resolver.sh"
export RESOLVER_CALLS="$TMP/resolver-calls"

# ---------------------------------------------------------------- fixture repo
build() {
  rm -rf "$ORIGIN" "$MAIN" "$TMP/state" "$TMP/wt" "$STUB_GITEA".* "$TMP/gate-calls" "$RESOLVER_CALLS"
  git init -q --bare "$ORIGIN"
  git clone -q "$ORIGIN" "$MAIN" 2>/dev/null
  cd "$MAIN" || exit 1
  git checkout -q -b develop
  mkdir -p .agent-pool src
  printf 'version = 1\n\n[[gate]]\nname = "unit"\nargv = ["just", "gate"]\npaths = ["src/**"]\n' > .agent-pool/gates.toml
  printf 'one\ntwo\nthree\n' > src/shared.txt
  git add -A; git commit -q -m base; git push -q origin develop
  # PR 7: touches its own file; develop then moves on elsewhere -> clean merge.
  git checkout -q -b feature/clean; echo mine > src/clean.txt; git add -A; git commit -q -m clean; git push -q origin feature/clean
  # PR 8: edits line two of the shared file; develop edits it too -> conflict.
  git checkout -q develop; git checkout -q -b feature/conflict
  sed -i 's/^two$/two (pr)/' src/shared.txt; git commit -q -am conflict; git push -q origin feature/conflict
  # PR 9 (below) is cut from develop's new tip, so it is already up to date.
  git checkout -q develop
  sed -i 's/^two$/two (develop)/' src/shared.txt; echo d > src/dev.txt; git add -A; git commit -q -m "develop moves"; git push -q origin develop
  git checkout -q -b feature/current; echo cur > src/cur.txt; git add -A; git commit -q -m current; git push -q origin feature/current
  git checkout -q --detach develop
  cd - >/dev/null || exit 1
  python3 - "$STUB_GITEA" "$@" <<'PY'
import json, sys
labels = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
prs = {"7": "feature/clean", "8": "feature/conflict", "9": "feature/current"}
json.dump({"prs": {n: {"head_ref": h, "labels": labels.get(n, ["agent:done", "review:clean"]), "comments": []}
                   for n, h in prs.items()}}, open(sys.argv[1], "w"))
PY
}

tick() { # [script [pool-root]]
  # No pool-root argument forces the stub pool, which is what every existing case wants. An empty
  # pool-root leaves PR_LOOP_POOL_ROOT unset so the script resolves it from .deployed-from or its path.
  local script="${1:-$COMMON/pr-update.sh}" pool_env=()
  if [ "$#" -ge 2 ] && [ -z "$2" ]; then
    pool_env=(env -u PR_LOOP_POOL_ROOT)
  else
    pool_env=(env "PR_LOOP_POOL_ROOT=${2:-$POOL}")
  fi
  "${pool_env[@]}" \
    PR_LOOP_REPO=o/r PR_LOOP_MAIN="$MAIN" PR_LOOP_STATE="$TMP/state" PR_UPDATE_WORKTREES="$TMP/wt" \
    AGENT_POOL_STATE="$TMP/poolstate" PR_UPDATE_RESOLVER="${RESOLVER-$TMP/resolver.sh}" \
    PR_LOOP_SKIP_PATTERN="" bash "$script" > "$TMP/out.txt" 2>&1
  TICK_RC=$?
}
labels_of() { python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1]))["prs"][sys.argv[2]]["labels"]))' "$STUB_GITEA" "$1"; }
comments_of() { python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["prs"][sys.argv[2]]["comments"]))' "$STUB_GITEA" "$1"; }
head_of() { git --git-dir "$ORIGIN" rev-parse "refs/heads/$1"; }
writes() { cat "$STUB_GITEA.writes" 2>/dev/null; }

pass=0; fail=0
expect() { # name got wanted-substring
  if [[ "$2" == *"$3"* ]]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n         wanted *%s*\n         got %s\n' "$1" "$3" "$2"; sed 's/^/           | /' "$TMP/out.txt" | tail -12; fi
}
expect_not() { # name got unwanted-substring
  if [[ "$2" != *"$3"* ]]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n         did not want *%s*\n         got %s\n' "$1" "$3" "$2"; sed 's/^/           | /' "$TMP/out.txt" | tail -12; fi
}
contains_develop() { git --git-dir "$ORIGIN" merge-base --is-ancestor "$(head_of develop)" "$(head_of "$1")" && echo yes || echo no; }

echo "clean merge"
build
before9="$(head_of feature/current)"; dev_before="$(head_of develop)"
RESOLVER="" tick
expect "the tick succeeds" "$TICK_RC" "0"
expect "#7 now contains develop" "$(contains_develop feature/clean)" "yes"
expect "  ... as a merge commit on top of its old head (no rebase)" "$(git --git-dir "$ORIGIN" log -1 --format=%P "$(head_of feature/clean)" | wc -w)" "2"
expect "  ... the gates ran on the merged tree" "$(cat "$TMP/gate-calls")" "run unit in .agent-pool src"
expect "  ... #7 asks for a fresh review" "$(labels_of 7)" "review:requested"
expect_not "  ... and drops its stale review:clean" "$(labels_of 7)" "review:clean"
expect_not "  ... and its stale agent:done" "$(labels_of 7)" "agent:done"
expect "  ... with a comment saying what happened" "$(comments_of 7)" "Automated update: merged \`develop\`"
expect "#9 already contains develop: untouched" "$(head_of feature/current)" "$before9"
expect_not "  ... and not relabelled" "$(writes)" "label 9"
expect "develop itself is never written" "$(head_of develop)" "$dev_before"
expect "#8's conflict with no resolver goes to a human" "$(labels_of 8)" "review:needs-human"
expect "  ... nothing pushed to it" "$(contains_develop feature/conflict)" "no"
expect "  ... the comment names the file" "$(comments_of 8)" "src/shared.txt"
tick
expect "a second tick is a no-op for the updated PR" "$(grep -c 'label 7' "$STUB_GITEA.writes")" "1"
expect "  ... and leaves the needs-human PR alone" "$(cat "$TMP/out.txt")" "#8: busy or waiting on a human (review:needs-human)"

echo
echo "AI conflict resolution"
build
tick
expect "the resolver is given exactly the conflicted file" "$(cat "$RESOLVER_CALLS")" "resolver pr=8 files=src/shared.txt"
expect "#8 now contains develop" "$(contains_develop feature/conflict)" "yes"
expect "  ... with the resolution committed" "$(git --git-dir "$ORIGIN" show "$(head_of feature/conflict)":src/shared.txt)" "two (pr)"
expect_not "  ... and no markers" "$(git --git-dir "$ORIGIN" show "$(head_of feature/conflict)":src/shared.txt)" "<<<<<<<"
expect "  ... review requested" "$(labels_of 8)" "review:requested"
expect "  ... the comment says the AI resolved it" "$(comments_of 8)" "resolved by the AI conflict resolver"

build; RESOLVER_BEHAVE=markers tick
expect "a resolver that leaves markers: needs-human" "$(labels_of 8)" "review:needs-human"
expect "  ... nothing pushed" "$(contains_develop feature/conflict)" "no"
expect "  ... and why" "$(comments_of 8)" "left conflict markers in src/shared.txt"

build; RESOLVER_BEHAVE=stray tick
expect "a resolver that touches another file: needs-human" "$(comments_of 8)" "changed files outside the conflict: stray.txt"
expect "  ... nothing pushed" "$(contains_develop feature/conflict)" "no"

build; RESOLVER_BEHAVE=fail tick
expect "a resolver that fails: needs-human" "$(comments_of 8)" "could not resolve src/shared.txt"

build; PR_UPDATE_MAX_CONFLICT_LINES=2 tick
expect "a conflict over the line limit is too large" "$(comments_of 8)" "too large to resolve automatically"
expect "  ... and the resolver is never asked" "[$(cat "$RESOLVER_CALLS" 2>/dev/null)]" "[]"

echo
echo "gates"
build; GATE_BEHAVE=gate-fail tick
expect "a red gate: needs-human" "$(labels_of 7)" "review:needs-human"
expect "  ... nothing pushed" "$(contains_develop feature/clean)" "no"
expect "  ... the comment carries the gate result" "$(comments_of 7)" "gates gate-fail"
build; GATE_BEHAVE=infra tick
expect "a broken gate run leaves the PR as it was" "$(labels_of 7)" "agent:done,review:clean"
expect "  ... nothing pushed" "$(contains_develop feature/clean)" "no"
expect "  ... and says the next tick retries" "$(cat "$TMP/out.txt")" "the next tick retries"

echo
echo "skips"
build '{"7": ["agent:claimed"], "8": ["review:in-progress"]}'
tick
expect "a claimed PR is not updated" "$(contains_develop feature/clean)" "no"
expect "  ... a PR under review neither" "$(contains_develop feature/conflict)" "no"
expect "  ... and nothing is written" "[$(writes)]" "[]"
build
DRY_RUN=1 tick
expect "dry run says what it would do" "$(cat "$TMP/out.txt")" "DRY: #7"
expect "  ... and writes nothing" "[$(writes)]" "[]"
expect "  ... pushes nothing" "$(contains_develop feature/clean)" "no"
build
PR_LOOP_PR=8 RESOLVER="" tick
expect "PR_LOOP_PR limits the tick to one PR" "$(contains_develop feature/clean)" "no"
python3 - "$STUB_GITEA" <<'PY'
import json, sys
st = json.load(open(sys.argv[1])); st["prs"]["7"]["base_ref"] = "master"; json.dump(st, open(sys.argv[1], "w"))
PY
rm -f "$STUB_GITEA.writes"; tick
expect "a PR based elsewhere is not updated" "$(contains_develop feature/clean)" "no"

echo
echo "pr-update-resolve.sh (the AI conduit), with a stub claude"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
prompt="$(cat)"
{ echo "ARGS=$*"; echo "KEY=${ANTHROPIC_API_KEY-unset}"; echo "PUSHURL=$GIT_CONFIG_VALUE_0"; } >> "$STUB_CLAUDE_LOG"
report="$(printf '%s\n' "$prompt" | sed -n 's/^When you are finished, write one line to \(.*\): RESOLVED.*/\1/p')"
case "${STUB_CLAUDE:-ok}" in
  ok) while IFS= read -r f; do
        [ -n "$f" ] || continue
        awk '/^<<<<<<< /{k=1; next} /^=======$/{k=0; next} /^>>>>>>> /{k=1; next} {if (k!=0) print}' "$f" > "$f.t" && mv "$f.t" "$f"
      done < <(printf '%s\n' "$prompt" | sed -n 's/^- //p')
      echo RESOLVED > "$report" ;;
  cannot) echo CANNOT_RESOLVE > "$report" ;;
  limit) echo '{"type":"result","subtype":"success","is_error":true,"result":"You have hit your usage limit"}'; exit 1 ;;
esac
echo '{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"s"}'
SH
chmod +x "$TMP/bin/claude"
export STUB_CLAUDE_LOG="$TMP/claude-log"
build
# Only the resolver is real here: it reads policy.py, classify.py and cooldown.py from the pool
# root pr-update.sh hands it, so the stub root links the real ones in beside the stub gates.py.
ANTHROPIC_API_KEY=stale CLAUDE_BIN="$TMP/bin/claude" PR_UPDATE_PROVIDERS=claude \
  RESOLVER="$ROOT/pr-update-resolve.sh" tick
expect "the real resolver drives claude to a resolution" "$(contains_develop feature/conflict)" "yes"
expect "  ... claude never sees the inherited API key" "$(cat "$STUB_CLAUDE_LOG")" "KEY=unset"
expect "  ... its pushes go nowhere" "$(cat "$STUB_CLAUDE_LOG")" "PUSHURL=/nonexistent/"
expect "  ... it runs under the pool's policy (a deny list)" "$(cat "$STUB_CLAUDE_LOG")" "--disallowedTools"
build; rm -f "$STUB_CLAUDE_LOG"
STUB_CLAUDE=cannot ANTHROPIC_API_KEY=stale CLAUDE_BIN="$TMP/bin/claude" PR_UPDATE_PROVIDERS=claude \
  RESOLVER="$ROOT/pr-update-resolve.sh" tick
expect "a provider that cannot resolve sends the PR to a human" "$(labels_of 8)" "review:needs-human"
expect "  ... nothing pushed" "$(contains_develop feature/conflict)" "no"
build; rm -f "$STUB_CLAUDE_LOG"
STUB_CLAUDE=limit ANTHROPIC_API_KEY=stale CLAUDE_BIN="$TMP/bin/claude" PR_UPDATE_PROVIDERS=claude \
  RESOLVER="$ROOT/pr-update-resolve.sh" tick
expect "a limited provider: needs-human, nothing pushed" "$(contains_develop feature/conflict)" "no"
expect "  ... and the limit is recorded as a pool cooldown" "$(cat "$TMP/poolstate/cooldowns/claude.json" 2>/dev/null)" "pr-update conflict resolve"

echo
echo "installed layout (POOL_ROOT from .deployed-from, not two levels above the script)"
INSTALLED="$TMP/home/.claude/skills/pr-loops-common"
mkdir -p "$INSTALLED"
cp "$ROOT/pr-update.sh" "$INSTALLED/pr-update.sh"
cp "$COMMON/gitea-pr.py" "$INSTALLED/gitea-pr.py"
printf 'commit %s\nref %s\ndeployed_at %s\nsource %s\n' abc refs/heads/develop 2026-01-01T00:00:00Z "$POOL" \
  > "$INSTALLED/.deployed-from"
build
RESOLVER="" tick "$INSTALLED/pr-update.sh" ""
expect "a deployed copy finds the pool via .deployed-from" "$(cat "$TMP/gate-calls" 2>/dev/null)" "run unit in .agent-pool src"
expect "  ... and updates the clean PR" "$(contains_develop feature/clean)" "yes"
expect "  ... rather than an infra skip" "$(labels_of 7)" "review:requested"

printf 'commit %s\nref %s\ndeployed_at %s\nsource %s\n' abc refs/heads/develop 2026-01-01T00:00:00Z "$TMP/bogus" \
  > "$INSTALLED/.deployed-from"
build
RESOLVER="" tick "$INSTALLED/pr-update.sh" ""
fallback="$(cd -- "$(dirname -- "$(readlink -f -- "$INSTALLED/pr-update.sh")")/../.." && pwd)"
expect "a bad .deployed-from source falls back above the script" "$(cat "$TMP/out.txt")" \
  "the gate runner $fallback/agent-pool/scripts/gates.py is missing"
expect_not "  ... and does not use the bogus source" "$(cat "$TMP/out.txt")" "$TMP/bogus"
expect "  ... so the clean PR is left alone" "$(contains_develop feature/clean)" "no"

build
RESOLVER="" tick "$INSTALLED/pr-update.sh" "$POOL"
expect "PR_LOOP_POOL_ROOT wins over a bad .deployed-from" "$(cat "$TMP/gate-calls" 2>/dev/null)" "run unit in .agent-pool src"
expect "  ... and the clean PR is updated" "$(contains_develop feature/clean)" "yes"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
