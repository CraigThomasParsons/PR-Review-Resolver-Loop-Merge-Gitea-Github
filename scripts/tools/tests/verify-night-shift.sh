#!/usr/bin/env bash
# Offline cases for scripts/tools/night_shift.sh and night_shift_maintenance.sh (#18).
#
# A temporary bare "origin" and project clone carry the launcher, policy.py and AGENTS.md; a
# stub cursor-agent acts per STUB_MODE; tests/fake-gitea.py answers the Gitea calls on loopback.
# No network, no real provider, no real token: HOME is a temp directory.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
PIDS=()
cleanup() {
  local pid
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"
unset GITEA_TOKEN NIGHT_CREW_TASK_RECEIPT http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch master

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1 ($2)"; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
ALL_OUTPUT="$TMP/all-output.txt"
: > "$ALL_OUTPUT"

SECRET="gitea-fixture-$RANDOM$RANDOM$RANDOM"
TOKEN_FILE="$TMP/gitea_token"
printf '%s\n' "$SECRET" > "$TOKEN_FILE"
export NIGHT_SHIFT_GITEA_TOKEN_FILE="$TOKEN_FILE"

REPO="craigpars/PR-Review-Resolver-Loop-Merge-Gitea-Github"
GITEA="$TMP/gitea"
mkdir -p "$GITEA"
python3 "$ROOT/scripts/tools/tests/fake-gitea.py" "$GITEA" "$SECRET" &
PIDS+=("$!")
for _ in $(seq 1 50); do [ -s "$GITEA/port" ] && break; sleep 0.1; done
export GITEA_BASE_URL="http://127.0.0.1:$(cat "$GITEA/port")"
printf '{"number": 7, "title": "Add a widget", "body": "Make `widget.txt`. $(touch /tmp/never) Gate: bash agent-pool/tests/verify-widget.sh; not ../../etc/verify-x.sh"}' > "$GITEA/issue.json"

# Stub cursor-agent: records its argv and the cli.json it was given, then acts per STUB_MODE.
STUB="$TMP/bin/cursor-agent"
mkdir -p "$TMP/bin"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_STATE/argv"
cp .cursor/cli.json "$STUB_STATE/cli.json" 2>/dev/null
echo '{"type":"system","subtype":"init"}'
case "${STUB_MODE:-commit}" in
  commit) echo widget > widget.txt; git add widget.txt; git commit -qm "add widget"
    echo '{"type":"tool_call","tool_call":{"shellToolCall":{"result":{"rejected":{"command":"a; b"}}}}}'
    echo '{"type":"result","subtype":"success","result":"done","permission_denials":[{"tool_name":"Shell","command":"a; b"}]}' ;;
  errorresult) echo e > err.txt; git add err.txt; git commit -qm "partial"; echo '{"type":"result","subtype":"error","is_error":true}' ;;
  deniedlimit) echo '{"type":"tool_call","tool_call":{"shellToolCall":{"result":{"rejected":{"command":"a; b"}}}}}'
    echo "You've hit your usage limit. Resets at 3am."; exit 1 ;;
  deniedshortlimit) echo d > denied.txt; git add denied.txt; git commit -qm "partial"
    echo '{"type":"tool_call","tool_call":{"shellToolCall":{"result":{"rejected":{"command":"a; b"}}}}}'
    echo '{"type":"result","subtype":"success","result":"You have hit your usage limit."}' ;;
  deniedlogin) echo '{"type":"tool_call","tool_call":{"shellToolCall":{"result":{"rejected":{"command":"a; b"}}}}}'
    echo "Error: not logged in"; exit 1 ;;
  shortlimit) echo s > short.txt; git add short.txt; git commit -qm "partial"; echo '{"type":"result","subtype":"success","result":"You have hit your usage limit."}' ;;
  secret) echo x > .env.local; git add .env.local; git commit -qm "oops" ;;
  nocommit) echo '{"type":"result","result":"nothing to do"}' ;;
  limit) echo "You've hit your usage limit. Resets at 3am."; exit 1 ;;
  readlimit) echo '{"type":"tool_call","subtype":"completed","tool_call":{"readToolCall":{"result":{"success":{"content":"this module is rate-limitable; rate limit 429"}}}}}'; exit 1 ;;
  fail) echo "something broke"; exit 1 ;;
esac
SH
chmod +x "$STUB"
export CURSOR_AGENT_BIN="$STUB"
export STUB_STATE="$TMP/stub"
mkdir -p "$STUB_STATE"

# Origin and project clone with the files the launcher needs at their real paths.
SEED="$TMP/seed"
mkdir -p "$SEED/scripts/tools" "$SEED/agent-pool/scripts" "$SEED/agent-pool/tests" "$SEED/skills/pr-loops-common"
cp "$ROOT/scripts/tools/night_shift.sh" "$ROOT/scripts/tools/night_shift_maintenance.sh" \
  "$ROOT/scripts/tools/night_shift_gitea.py" "$SEED/scripts/tools/"
cp "$ROOT/agent-pool/scripts/policy.py" "$ROOT/agent-pool/scripts/classify.py" "$SEED/agent-pool/scripts/"
cp "$ROOT/AGENTS.md" "$SEED/"
printf '#!/usr/bin/env bash\n[ -z "${AGENT_POOL_MAIN:-}" ]\n' > "$SEED/agent-pool/tests/verify-ok.sh"
touch "$SEED/skills/pr-loops-common/gitea-pr.py"
git -C "$SEED" init -q
git -C "$SEED" add -A
git -C "$SEED" commit -qm seed
git clone -q --bare "$SEED" "$TMP/origin.git"
PROJECT="$TMP/project"
git clone -q "$TMP/origin.git" "$PROJECT"
LAUNCHER="$PROJECT/scripts/tools/night_shift.sh"
MAINT="$PROJECT/scripts/tools/night_shift_maintenance.sh"

run() { # args... -> OUT, CODE
  OUT="$(bash "$LAUNCHER" "$@" 2>&1)"
  CODE=$?
  printf '%s\n' "$OUT" >> "$ALL_OUTPUT"
}
remote_has_branch() { git -C "$TMP/origin.git" show-ref --verify --quiet "refs/heads/$1" && echo yes || echo no; }
created_count() { if [ -f "$GITEA/created.jsonl" ]; then wc -l < "$GITEA/created.jsonl" | tr -d ' '; else echo 0; fi; }

echo "argument validation"
run
same "no arguments -> exit 2" "$CODE" 2
run "$PROJECT" abc
same "non-numeric issue -> exit 2" "$CODE" 2
run relative/path 7
same "relative project_dir -> exit 2" "$CODE" 2
run "$TMP/missing" 7
same "missing project_dir -> exit 2" "$CODE" 2
run "$PROJECT" 7 claude
same "non-cursor agent -> exit 2" "$CODE" 2
case "$OUT" in *"runs only cursor"*) ok "non-cursor agent is named in the refusal" ;; *) bad "non-cursor agent is named" "$OUT" ;; esac
same "no agent ran for refused arguments" "$( [ -e "$STUB_STATE/argv" ] && echo ran || echo none)" none

echo
echo "lock held"
mkdir -p "$PROJECT/logs"
exec 8>"$PROJECT/logs/night_shift.flock"
flock -n 8
run "$PROJECT" 7
same "a held lock -> exit 3" "$CODE" 3
case "$OUT" in *"Another issue is already locked"*) ok "lock refusal uses the client's pre-flight conflict wording" ;; *) bad "lock wording" "$OUT" ;; esac
same "no agent ran while locked" "$( [ -e "$STUB_STATE/argv" ] && echo ran || echo none)" none
flock -u 8
exec 8>&-

echo
echo "dirty tree"
echo scratch > "$PROJECT/scratch.txt"
run "$PROJECT" 7
same "a dirty project checkout -> exit 1" "$CODE" 1
same "the lock file is removed after a refusal" "$( [ -e "$PROJECT/logs/night_shift.lock" ] && echo present || echo gone)" gone
rm -f "$PROJECT/scratch.txt"

echo
echo "dirty leftover worktree"
git -C "$PROJECT" worktree add -q --detach "$PROJECT/logs/worktrees/issue-7" origin/master
echo "unsaved work" > "$PROJECT/logs/worktrees/issue-7/unsaved.txt"
run "$PROJECT" 7
same "a dirty leftover worktree -> exit 1" "$CODE" 1
case "$OUT" in *"Unowned worktree exists"*) ok "the leftover worktree is reported" ;; *) bad "leftover report" "$OUT" ;; esac
same "the leftover's uncommitted work survives the abort" \
  "$(cat "$PROJECT/logs/worktrees/issue-7/unsaved.txt" 2>/dev/null)" "unsaved work"
same "no agent ran beside a leftover worktree" "$( [ -e "$STUB_STATE/argv" ] && echo ran || echo none)" none
git -C "$PROJECT" worktree remove --force "$PROJECT/logs/worktrees/issue-7"

echo
echo "stale worktree directory git no longer registers"
mkdir -p "$PROJECT/logs/worktrees/issue-7"
echo "orphaned work" > "$PROJECT/logs/worktrees/issue-7/orphan.txt"
run "$PROJECT" 7
same "a stale worktree directory -> exit 1" "$CODE" 1
case "$OUT" in *"Stale worktree directory"*) ok "the stale directory is reported for a human" ;; *) bad "stale directory report" "$OUT" ;; esac
same "the stale directory's files survive the abort" \
  "$(cat "$PROJECT/logs/worktrees/issue-7/orphan.txt" 2>/dev/null)" "orphaned work"
same "no agent ran beside a stale directory" "$( [ -e "$STUB_STATE/argv" ] && echo ran || echo none)" none
rm -rf "$PROJECT/logs/worktrees/issue-7"

echo
echo "stale worktree whose .git file points at removed metadata"
git -C "$PROJECT" worktree add -q --detach "$PROJECT/logs/worktrees/issue-7" origin/master
WT_META="$(git -C "$PROJECT/logs/worktrees/issue-7" rev-parse --absolute-git-dir)"
rm -rf "$WT_META"
echo "dangling work" > "$PROJECT/logs/worktrees/issue-7/dangling.txt"
run "$PROJECT" 7
same "a worktree with removed metadata -> exit 1" "$CODE" 1
case "$OUT" in *"Stale worktree directory"*) ok "the dangling worktree is reported for a human" ;; *) bad "dangling worktree report" "$OUT" ;; esac
same "the dangling worktree's files survive the abort" \
  "$(cat "$PROJECT/logs/worktrees/issue-7/dangling.txt" 2>/dev/null)" "dangling work"
same "no agent ran beside a dangling worktree" "$( [ -e "$STUB_STATE/argv" ] && echo ran || echo none)" none
rm -rf "$PROJECT/logs/worktrees/issue-7"
git -C "$PROJECT" worktree prune

echo
echo "agent exits 0 without a commit"
NIGHT_CREW_TASK_RECEIPT="$TMP/receipts/nocommit.json" STUB_MODE=nocommit run "$PROJECT" 7
same "no commit -> exit 1" "$CODE" 1
same "no branch pushed" "$(remote_has_branch feature/7-nightcrew)" no
same "no PR opened" "$(created_count)" 0
same "no receipt for a run with nothing to publish" "$( [ -e "$TMP/receipts/nocommit.json" ] && echo written || echo none)" none
same "the worktree is removed" "$( [ -d "$PROJECT/logs/worktrees/issue-7" ] && echo present || echo gone)" gone

echo
echo "agent failure and provider limit"
echo '{"pid": 1, "issue": 7}' > "$PROJECT/logs/night_shift.lock"
STUB_MODE=fail run "$PROJECT" 7
same "agent failure -> exit 1" "$CODE" 1
case "$OUT" in *"replacing a stale"*) ok "a stale lock file without the flock is replaced" ;; *) bad "stale lock" "$OUT" ;; esac
same "the replaced lock is removed on exit" "$( [ -e "$PROJECT/logs/night_shift.lock" ] && echo present || echo gone)" gone
STUB_MODE=readlimit run "$PROJECT" 7
same "limit wording only in what the worker read -> exit 1, not 75" "$CODE" 1
STUB_MODE=limit run "$PROJECT" 7
same "provider limit -> exit 75" "$CODE" 75
case "$OUT" in *"PARK: provider limit reached"*) ok "limit prints the client's PARK marker" ;; *) bad "PARK marker" "$OUT" ;; esac
same "no branch pushed after failures" "$(remote_has_branch feature/7-nightcrew)" no

echo
echo "credential-shaped filename"
git -C "$PROJECT" branch -D feature/7-nightcrew >/dev/null 2>&1
STUB_MODE=secret run "$PROJECT" 7
same "a .env file on the branch -> exit 1" "$CODE" 1
same "nothing pushed for a credential-shaped filename" "$(remote_has_branch feature/7-nightcrew)" no
git -C "$PROJECT" branch -D feature/7-nightcrew >/dev/null 2>&1

echo
echo "clean exit without a successful result"
STUB_MODE=errorresult run "$PROJECT" 7
same "exit 0 with an error result -> exit 1" "$CODE" 1
same "nothing pushed for an error result" "$(remote_has_branch feature/7-nightcrew)" no
git -C "$PROJECT" branch -D feature/7-nightcrew >/dev/null 2>&1
STUB_MODE=shortlimit run "$PROJECT" 7
same "exit 0 with a short usage-limit result -> exit 75 even with a commit" "$CODE" 75
same "nothing pushed for a limit" "$(remote_has_branch feature/7-nightcrew)" no
git -C "$PROJECT" branch -D feature/7-nightcrew >/dev/null 2>&1
STUB_MODE=deniedlimit run "$PROJECT" 7
same "a denied tool call does not hide a provider limit (nonzero exit) -> exit 75" "$CODE" 75
STUB_MODE=deniedshortlimit run "$PROJECT" 7
same "a denied tool call does not hide a short usage-limit result (exit 0) -> exit 75" "$CODE" 75
same "nothing pushed for a limit behind a denial" "$(remote_has_branch feature/7-nightcrew)" no
git -C "$PROJECT" branch -D feature/7-nightcrew >/dev/null 2>&1
STUB_MODE=deniedlogin run "$PROJECT" 7
same "a real setup signature behind a denial -> exit 1" "$CODE" 1
case "$OUT" in *"classified without denied tool calls — setup"*) ok "the setup signature survives the second classification" ;;
  *) bad "setup behind a denial" "$OUT" ;; esac

echo
echo "push rejected"
printf '#!/bin/sh\nexit 1\n' > "$TMP/origin.git/hooks/pre-receive"
chmod +x "$TMP/origin.git/hooks/pre-receive"
STUB_MODE=commit run "$PROJECT" 7
rm -f "$TMP/origin.git/hooks/pre-receive"
same "a rejected push -> exit 1" "$CODE" 1
case "$OUT" in *"ERROR push of feature/7-nightcrew rejected"*) ok "a rejected push is logged" ;; *) bad "push rejected log" "$OUT" ;; esac
same "no PR opened after a rejected push" "$(created_count)" 0
git -C "$PROJECT" branch -D feature/7-nightcrew >/dev/null 2>&1

echo
echo "success"
RECEIPT="$TMP/receipts/job-1.json"
NIGHT_CREW_TASK_RECEIPT="$RECEIPT" STUB_MODE=commit run "$PROJECT" 7
same "success (with a denied compound command along the way) -> exit 0" "$CODE" 0
same "branch pushed by the launcher" "$(remote_has_branch feature/7-nightcrew)" yes
same "one PR opened" "$(created_count)" 1
pr_fields="$(python3 -c 'import json,sys; b=json.loads(open(sys.argv[1]).readline()); print(b["head"], b["base"], b["title"], "Closes #7" in b["body"])' "$GITEA/created.jsonl")"
same "PR head/base/title/closing reference" "$pr_fields" "feature/7-nightcrew master #7: Add a widget True"
remote_head="$(git -C "$TMP/origin.git" rev-parse refs/heads/feature/7-nightcrew)"
receipt="$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["pr_number"], r["branch"], r["head"])' "$RECEIPT" 2>&1)"
same "receipt names PR, branch and pushed head" "$receipt" "99 feature/7-nightcrew $remote_head"
same "the lock file is removed" "$( [ -e "$PROJECT/logs/night_shift.lock" ] && echo present || echo gone)" gone
same "the project checkout stays clean" "$(git -C "$PROJECT" status --porcelain)" ""
argv="$(tr '\n' ' ' < "$STUB_STATE/argv")"
case "$argv" in *"-p --trust --workspace $PROJECT/logs/worktrees/issue-7 --output-format stream-json --model auto"*) ok "cursor-agent gets -p --trust --workspace --model" ;; *) bad "cursor argv" "$argv" ;; esac
case "$argv" in *"--force"*|*"--yolo"*) bad "no --force" "$argv" ;; *) ok "cursor-agent never gets --force" ;; esac
case "$argv" in *'$(touch /tmp/never)'*) ok "issue text reaches the prompt as data" ;; *) bad "issue text in prompt" "missing" ;; esac
case "$argv" in *"verify-*.sh script that exists in this worktree"*) ok "the prompt names the gates the allow list grants" ;; *) bad "prompt gate wording" "missing" ;; esac
cli="$(python3 - "$STUB_STATE/cli.json" "$(cd "$PROJECT" && pwd -P)" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))["permissions"]
allow, deny = p["allow"], p["deny"]
project = sys.argv[2]
adapter_reads = [a for a in allow if "gitea-pr.py" in a]
print(bool(adapter_reads) and all(a.startswith(f"Shell(python3 {project}/skills/") for a in adapter_reads),
      all(x in allow for x in ("Shell(python3 -m unittest)", "Shell(python3 -m behave)",
                               "Shell(bash agent-pool/tests/verify-ok.sh)", "Shell(git commit -m)")),
      "Shell(git push)" in deny, any(d.startswith("Read(") and ".config/pulse" in d for d in deny),
      any(a.startswith("Shell(python3 -c") or a == "Shell(python3)" for a in allow),
      "Shell(bash agent-pool/tests/verify-widget.sh)" in allow and not any("etc/verify-x" in a for a in allow))
PY
)"
same "cli.json: project adapter; tests, commits and issue-named gates allowed; push, credential reads, ../ paths denied" \
  "$cli" "True True True True False True"
# Effective decision, as Cursor applies it: allowed only when an allow prefix matches and no deny
# prefix does. Checked under both readings of "prefix" (whole tokens, and plain string), since
# a test command a deny rule shadows would leave the worker unable to run its gate.
effective="$(python3 - "$STUB_STATE/cli.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))["permissions"]
shell = lambda rules: [r[len("Shell("):-1] for r in rules if r.startswith("Shell(")]
allow, deny = shell(p["allow"]), shell(p["deny"])
token = lambda cmd, pre: cmd == pre or cmd.startswith(pre + " ")
string = lambda cmd, pre: cmd.startswith(pre)
def decide(cmd):
    verdicts = {any(m(cmd, a) for a in allow) and not any(m(cmd, d) for d in deny) for m in (token, string)}
    return "allow" if verdicts == {True} else "deny" if verdicts == {False} else "split"
for cmd in ("bash agent-pool/tests/verify-ok.sh", "python3 -m unittest discover -s agent-pool/tests/conduits -v",
            "python3 -m behave agent-pool/tests/features/conduits.feature --strict", "git commit -m msg",
            "git push origin HEAD", "bash -c id", "bash /tmp/x.sh", "python3 -c 1", "python3 x.py",
            "curl http://x", "sh x", "env"):
    print(cmd.split()[0] + ":" + decide(cmd), end=" ")
PY
)"
same "effective permissions: tests and commit run; push, shells, inline python, network denied" "$effective" \
  "bash:allow python3:allow python3:allow git:allow git:deny bash:deny bash:deny python3:deny python3:deny curl:deny sh:deny env:deny "
same "all Gitea requests were authorized" "$(grep -c ' unauthorized$' "$GITEA/requests.log")" 0

echo
echo "rerun reuses the open PR, found on a later page"
python3 - "$GITEA/pulls.json" "$REPO" <<'PY'
import json, sys
repo = {"full_name": sys.argv[2]}
others = [{"number": n, "html_url": f"http://gitea.test/p/{n}", "head": {"ref": f"feature/x-{n}", "repo": repo},
           "base": {"ref": "master", "repo": repo}} for n in range(1, 61)]
mine = {"number": 99, "html_url": "http://gitea.test/owner/repo/pulls/99",
        "head": {"ref": "feature/7-nightcrew", "repo": repo}, "base": {"ref": "master", "repo": repo}}
json.dump(others + [mine], open(sys.argv[1], "w"))
PY
NIGHT_CREW_TASK_RECEIPT="$RECEIPT" STUB_MODE=commit run "$PROJECT" 7
same "rerun -> exit 0" "$CODE" 0
same "no second PR created" "$(created_count)" 1

echo
echo "a launcher step fails after the PR is open"
touch "$TMP/receipt-blocker"
NIGHT_CREW_TASK_RECEIPT="$TMP/receipt-blocker/job.json" STUB_MODE=commit run "$PROJECT" 7
same "a failed receipt write -> exit 1" "$CODE" 1
case "$OUT" in *"[night_shift] "*"ERROR line "*"failed with exit 1"*) ok "the failed step is logged by the launcher" ;; *) bad "failed step log" "$OUT" ;; esac
same "the lock file is removed after a failed step" "$( [ -e "$PROJECT/logs/night_shift.lock" ] && echo present || echo gone)" gone

echo
echo "remote branch moved on"
SIDE="$TMP/side"
git clone -q "$TMP/origin.git" "$SIDE"
git -C "$SIDE" checkout -q feature/7-nightcrew
echo fix > "$SIDE/review-fix.txt"
git -C "$SIDE" add review-fix.txt
git -C "$SIDE" commit -qm "review fix"
git -C "$SIDE" push -q origin feature/7-nightcrew
STUB_MODE=nocommit run "$PROJECT" 7
same "a local branch behind the remote is fast-forwarded and published -> exit 0" "$CODE" 0
same "the local branch now carries the remote fix" \
  "$(git -C "$PROJECT" rev-parse feature/7-nightcrew)" "$(git -C "$TMP/origin.git" rev-parse refs/heads/feature/7-nightcrew)"
echo diverged > "$SIDE/remote-only.txt"
git -C "$SIDE" add remote-only.txt
git -C "$SIDE" commit -qm "remote only"
git -C "$SIDE" push -q origin feature/7-nightcrew
git -C "$PROJECT" worktree add -q "$TMP/local-wt" feature/7-nightcrew
echo local > "$TMP/local-wt/local-only.txt"
git -C "$TMP/local-wt" add local-only.txt
git -C "$TMP/local-wt" commit -qm "local only"
git -C "$PROJECT" worktree remove --force "$TMP/local-wt"
rm -f "$STUB_STATE/argv"
STUB_MODE=commit run "$PROJECT" 7
same "diverged local and remote branches -> exit 1" "$CODE" 1
case "$OUT" in *"have diverged"*) ok "divergence is reported before the agent runs" ;; *) bad "divergence" "$OUT" ;; esac
same "no agent ran on a diverged branch" "$( [ -e "$STUB_STATE/argv" ] && echo ran || echo none)" none

echo
echo "PR creation fails after the push: the published branch is kept for a rerun"
before="$(created_count)"
touch "$GITEA/post-fails"
NIGHT_CREW_TASK_RECEIPT="$TMP/receipts/issue-8.json" STUB_MODE=commit run "$PROJECT" 8
rm -f "$GITEA/post-fails"
same "a failed PR creation -> exit 1" "$CODE" 1
head8="$(git -C "$PROJECT" rev-parse feature/8-nightcrew 2>/dev/null)"
case "$OUT" in *"ERROR could not open or confirm a PR for feature/8-nightcrew at ${head8}; the pushed branch"*) ok "the failure log names the branch and its head" ;;
  *) bad "PR failure log" "$OUT" ;; esac
same "the pushed branch and its commit stay on the remote" \
  "$(git -C "$TMP/origin.git" rev-parse refs/heads/feature/8-nightcrew 2>/dev/null)" "$head8"
same "no receipt without a verified PR" "$( [ -e "$TMP/receipts/issue-8.json" ] && echo written || echo none)" none
same "no PR recorded" "$(created_count)" "$before"
same "the lock file is removed after a failed PR creation" "$( [ -e "$PROJECT/logs/night_shift.lock" ] && echo present || echo gone)" gone
NIGHT_CREW_TASK_RECEIPT="$TMP/receipts/issue-8.json" STUB_MODE=nocommit run "$PROJECT" 8
same "the rerun reuses the published commit and opens the PR -> exit 0" "$CODE" 0
same "one PR created by the rerun" "$(created_count)" "$((before + 1))"
same "the rerun's PR is from the kept branch into master" \
  "$(python3 -c 'import json,sys; b=json.loads(open(sys.argv[1]).readlines()[-1]); print(b["head"], b["base"])' "$GITEA/created.jsonl")" \
  "feature/8-nightcrew master"
same "the remote branch was not rewritten" "$(git -C "$TMP/origin.git" rev-parse refs/heads/feature/8-nightcrew)" "$head8"
same "the receipt names the new PR, the branch and the kept head" \
  "$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["pr_number"], r["branch"], r["head"])' "$TMP/receipts/issue-8.json" 2>&1)" \
  "$((99 + before)) feature/8-nightcrew $head8"

echo
echo "PR created but the response is lost: the rerun finds it instead of opening another"
before="$(created_count)"
touch "$GITEA/post-lost"
NIGHT_CREW_TASK_RECEIPT="$TMP/receipts/issue-9.json" STUB_MODE=commit run "$PROJECT" 9
rm -f "$GITEA/post-lost"
same "a lost PR creation response -> exit 1" "$CODE" 1
head9="$(git -C "$PROJECT" rev-parse feature/9-nightcrew 2>/dev/null)"
case "$OUT" in *"ERROR could not open or confirm a PR for feature/9-nightcrew at ${head9}"*) ok "the lost response is logged with the branch and head" ;;
  *) bad "lost response log" "$OUT" ;; esac
same "no receipt while the PR is unconfirmed" "$( [ -e "$TMP/receipts/issue-9.json" ] && echo written || echo none)" none
same "the branch stays on the remote" "$(git -C "$TMP/origin.git" rev-parse refs/heads/feature/9-nightcrew 2>/dev/null)" "$head9"
same "the server did create the PR" "$(created_count)" "$((before + 1))"
NIGHT_CREW_TASK_RECEIPT="$TMP/receipts/issue-9.json" STUB_MODE=nocommit run "$PROJECT" 9
same "the rerun reconciles the hidden PR -> exit 0" "$CODE" 0
same "no second PR for the same branch" "$(created_count)" "$((before + 1))"
same "the receipt names the PR the lost response hid" \
  "$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["pr_number"], r["branch"], r["head"])' "$TMP/receipts/issue-9.json" 2>&1)" \
  "$((99 + before)) feature/9-nightcrew $head9"

echo
echo "only a PR from this repository's branch into the base is reused"
before="$(created_count)"
python3 - "$GITEA/pulls.json" "$REPO" <<'PY'
import json, sys
path, repo = sys.argv[1], {"full_name": sys.argv[2]}
fork = {"full_name": "someone/fork"}
every = json.load(open(path))
every += [{"number": 501, "html_url": "http://gitea.test/p/501", "head": {"ref": "feature/10-nightcrew", "repo": fork},
           "base": {"ref": "master", "repo": repo}},
          {"number": 502, "html_url": "http://gitea.test/p/502", "head": {"ref": "feature/10-nightcrew", "repo": repo},
           "base": {"ref": "develop", "repo": repo}},
          {"number": 503, "html_url": "http://gitea.test/p/503", "head": {"ref": "feature/10-nightcrew", "repo": repo},
           "base": {"ref": None, "repo": repo}}]
json.dump(every, open(path, "w"))
PY
NIGHT_CREW_TASK_RECEIPT="$TMP/receipts/issue-10.json" STUB_MODE=commit run "$PROJECT" 10
same "a fork's, another base's or a baseless PR with the same branch name is not reused -> exit 0" "$CODE" 0
same "a PR of its own is opened" "$(created_count)" "$((before + 1))"
same "the receipt names the new PR, not a look-alike" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pr_number"])' "$TMP/receipts/issue-10.json" 2>&1)" \
  "$((99 + before))"

echo
echo "a created PR that does not match the branch is not trusted"
before="$(created_count)"
touch "$GITEA/post-mismatch"
NIGHT_CREW_TASK_RECEIPT="$TMP/receipts/issue-11.json" STUB_MODE=commit run "$PROJECT" 11
rm -f "$GITEA/post-mismatch"
same "a mismatched creation answer -> exit 1" "$CODE" 1
same "no receipt for an unverified PR" "$( [ -e "$TMP/receipts/issue-11.json" ] && echo written || echo none)" none
same "the branch stays on the remote for the rerun" "$(remote_has_branch feature/11-nightcrew)" yes

echo
echo "maintenance"
OUT="$(bash "$MAINT" "$PROJECT" unknown 2>&1)"; CODE=$?
same "unknown maintenance task -> exit 2" "$CODE" 2
OUT="$(bash "$MAINT" "$PROJECT" 2>&1)"; CODE=$?
same "missing maintenance task -> exit 2" "$CODE" 2
OUT="$(AGENT_POOL_MAIN=/leaked bash "$MAINT" "$PROJECT" quality 2>&1)"; CODE=$?
same "quality runs the offline suites without the caller's operator variables -> exit 0" "$CODE" 0
case "$OUT" in *"ok   agent-pool/tests/verify-ok.sh"*) ok "quality ran the verify suite" ;; *) bad "quality output" "$OUT" ;; esac

echo
echo "nothing secret is printed"
if grep -qF -- "$SECRET" "$ALL_OUTPUT" "$PROJECT/logs/night_shift_agent.log"; then bad "the token never appears in output" "found"
else ok "the token never appears in output"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
