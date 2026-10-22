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
case "${STUB_MODE:-edit}" in
  # The worker is edit-only: it writes files and never stages or commits (workercommit aside).
  edit) echo widget > widget.txt
    echo '{"type":"tool_call","tool_call":{"shellToolCall":{"result":{"rejected":{"command":"git commit -m \"add widget\""}}}}}'
    echo '{"type":"result","subtype":"success","result":"done","permission_denials":[{"tool_name":"Shell","command":"git commit -m \"add widget\""}]}' ;;
  editmany) mkdir -p src; echo one > src/one.txt; echo two > two.txt; echo more >> AGENTS.md
    echo '{"type":"result","subtype":"success","result":"edited"}' ;;
  edittoolconfig) echo kept > kept.txt; mkdir -p .cursor/rules .claude; echo r > .cursor/rules/r.mdc; echo c > .claude/settings.json
    echo '{"type":"result","subtype":"success","result":"edited"}' ;;
  errorresult) echo e > err.txt; echo '{"type":"result","subtype":"error","is_error":true}' ;;
  deniedlimit) echo '{"type":"tool_call","tool_call":{"shellToolCall":{"result":{"rejected":{"command":"a; b"}}}}}'
    echo "You've hit your usage limit. Resets at 3am."; exit 1 ;;
  deniedshortlimit) echo d > denied.txt
    echo '{"type":"tool_call","tool_call":{"shellToolCall":{"result":{"rejected":{"command":"a; b"}}}}}'
    echo '{"type":"result","subtype":"success","result":"You have hit your usage limit."}' ;;
  deniedlogin) echo '{"type":"tool_call","tool_call":{"shellToolCall":{"result":{"rejected":{"command":"a; b"}}}}}'
    echo "Error: not logged in"; exit 1 ;;
  shortlimit) echo s > short.txt; echo '{"type":"result","subtype":"success","result":"You have hit your usage limit."}' ;;
  secret) echo x > .env.local; echo '{"type":"result","subtype":"success","result":"done"}' ;;
  workercommit) echo w > rogue.txt; git add rogue.txt; git commit -qm "rogue"; echo '{"type":"result","subtype":"success","result":"done"}' ;;
  breaktests) echo widget > widget.txt; printf '#!/usr/bin/env bash\necho broken; exit 1\n' > agent-pool/tests/verify-broken.sh
    echo '{"type":"result","subtype":"success","result":"done"}' ;;
  deletetests) echo widget > widget.txt; rm agent-pool/tests/verify-ok.sh
    echo '{"type":"result","subtype":"success","result":"done"}' ;;
  editfail) echo edited > edited.txt; echo "something broke"; exit 1 ;;
  editlimit) echo edited > edited.txt; echo "You've hit your usage limit. Resets at 3am."; exit 1 ;;
  breaklimit) echo edited > edited.txt; printf '#!/usr/bin/env bash\nexit 1\n' > agent-pool/tests/verify-broken.sh
    echo "You've hit your usage limit. Resets at 3am."; exit 1 ;;
  # Records what the worker inherited (#25), as set/unset only so no value reaches a log, and
  # writes a suite that records whether the launcher's test run holds fd 9.
  probe) echo widget > widget.txt
    for var in GITEA_TOKEN NIGHT_SHIFT_GITEA_TOKEN_FILE NIGHT_CREW_TASK_RECEIPT NIGHT_CREW_TOKEN_FILE SSH_AUTH_SOCK; do
      if [ -n "${!var+x}" ]; then echo "$var=set"; else echo "$var=unset"; fi
    done > "$STUB_STATE/worker-env"
    if { : >&9; } 2>/dev/null; then echo open; else echo closed; fi > "$STUB_STATE/worker-fd9"
    if git push -q origin HEAD:refs/heads/worker-push 2>/dev/null; then echo pushed; else echo refused; fi > "$STUB_STATE/worker-push"
    cat > agent-pool/tests/verify-probe.sh <<PROBE
#!/usr/bin/env bash
if { : >&9; } 2>/dev/null; then echo open; else echo closed; fi > "$STUB_STATE/suite-fd9"
PROBE
    echo '{"type":"result","subtype":"success","result":"done"}' ;;
  noedit) echo '{"type":"result","result":"nothing to do"}' ;;
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
state_of() { # issue -> "state reason" from the launcher's state file, or "none"
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["state"], r["reason"])' \
    "$PROJECT/logs/runs/issue-$1-state.json" 2>/dev/null || echo none
}
state_message() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["message"])' "$PROJECT/logs/runs/issue-$1-state.json" 2>/dev/null; }
# A local branch that still sits on the base: nothing was committed on it.
on_base() { [ "$(git -C "$PROJECT" rev-parse "feature/$1-nightcrew" 2>/dev/null)" = "$(git -C "$PROJECT" rev-parse origin/master)" ] && echo yes || echo no; }
drop_issue() { # issue: forget a kept worktree and the local branch so the next case starts fresh
  git -C "$PROJECT" worktree remove --force "$PROJECT/logs/worktrees/issue-$1" 2>/dev/null
  git -C "$PROJECT" branch -D "feature/$1-nightcrew" >/dev/null 2>&1
}

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
echo "fail closed: the agent exits 0 without a change"
NIGHT_CREW_TASK_RECEIPT="$TMP/receipts/nocommit.json" STUB_MODE=noedit run "$PROJECT" 7
same "no diff -> exit 1" "$CODE" 1
case "$OUT" in *"FAILED no-diff:"*) ok "the no-diff failure is logged by name" ;; *) bad "no-diff log" "$OUT" ;; esac
same "the state file records the no-diff failure" "$(state_of 7)" "failed no-diff"
case "$(state_message 7)" in *"no change on feature/7-nightcrew"*) ok "the state file's message explains it" ;; *) bad "no-diff message" "$(state_message 7)" ;; esac
same "nothing committed on the local branch" "$(on_base 7)" yes
same "the no-diff run never ran the suites" "$( [ -e "$PROJECT/logs/runs/issue-7-tests.log" ] && echo ran || echo none)" none
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
same "an agent failure is recorded" "$(state_of 7)" "failed agent-failed"
STUB_MODE=limit run "$PROJECT" 7
same "provider limit -> exit 75" "$CODE" 75
case "$OUT" in *"PARK: provider limit reached"*) ok "limit prints the client's PARK marker" ;; *) bad "PARK marker" "$OUT" ;; esac
same "a park is recorded" "$(state_of 7)" "parked limit"
same "no branch pushed after failures" "$(remote_has_branch feature/7-nightcrew)" no

echo
echo "credential-shaped filename"
git -C "$PROJECT" branch -D feature/7-nightcrew >/dev/null 2>&1
STUB_MODE=secret run "$PROJECT" 7
same "a .env file in the worker's edits -> exit 1" "$CODE" 1
same "it is recorded as a forbidden path" "$(state_of 7)" "failed forbidden-path"
same "nothing committed for a credential-shaped filename" "$(on_base 7)" yes
same "nothing pushed for a credential-shaped filename" "$(remote_has_branch feature/7-nightcrew)" no
drop_issue 7

echo
echo "clean exit without a successful result"
STUB_MODE=errorresult run "$PROJECT" 7
same "exit 0 with an error result -> exit 1" "$CODE" 1
same "nothing committed for an error result" "$(on_base 7)" yes
same "nothing pushed for an error result" "$(remote_has_branch feature/7-nightcrew)" no
drop_issue 7
STUB_MODE=shortlimit run "$PROJECT" 7
same "exit 0 with a short usage-limit result -> exit 75 even with edits" "$CODE" 75
same "nothing pushed for a limit" "$(remote_has_branch feature/7-nightcrew)" no
drop_issue 7
STUB_MODE=deniedlimit run "$PROJECT" 7
same "a denied tool call does not hide a provider limit (nonzero exit) -> exit 75" "$CODE" 75
STUB_MODE=deniedshortlimit run "$PROJECT" 7
same "a denied tool call does not hide a short usage-limit result (exit 0) -> exit 75" "$CODE" 75
same "nothing pushed for a limit behind a denial" "$(remote_has_branch feature/7-nightcrew)" no
drop_issue 7
STUB_MODE=deniedlogin run "$PROJECT" 7
same "a real setup signature behind a denial -> exit 1" "$CODE" 1
case "$OUT" in *"classified without denied tool calls — setup"*) ok "the setup signature survives the second classification" ;;
  *) bad "setup behind a denial" "$OUT" ;; esac

echo
echo "push rejected"
printf '#!/bin/sh\nexit 1\n' > "$TMP/origin.git/hooks/pre-receive"
chmod +x "$TMP/origin.git/hooks/pre-receive"
STUB_MODE=edit run "$PROJECT" 7
rm -f "$TMP/origin.git/hooks/pre-receive"
same "a rejected push -> exit 1" "$CODE" 1
case "$OUT" in *"ERROR push of feature/7-nightcrew rejected"*) ok "a rejected push is logged" ;; *) bad "push rejected log" "$OUT" ;; esac
same "no PR opened after a rejected push" "$(created_count)" 0
same "a rejected push is recorded" "$(state_of 7)" "failed push-rejected"
drop_issue 7

echo
echo "success"
RECEIPT="$TMP/receipts/job-1.json"
NIGHT_CREW_TASK_RECEIPT="$RECEIPT" STUB_MODE=edit run "$PROJECT" 7
same "success (with a denied commit along the way) -> exit 0" "$CODE" 0
same "branch pushed by the launcher" "$(remote_has_branch feature/7-nightcrew)" yes
same "one PR opened" "$(created_count)" 1
pr_fields="$(python3 -c 'import json,sys; b=json.loads(open(sys.argv[1]).readline()); print(b["head"], b["base"], b["title"], "Closes #7" in b["body"])' "$GITEA/created.jsonl")"
same "PR head/base/title/closing reference" "$pr_fields" "feature/7-nightcrew master #7: Add a widget True"
same "the PR body says the launcher committed the edit-only worker's edits" \
  "$(python3 -c 'import json,sys; b=json.loads(open(sys.argv[1]).readline()); print("the launcher committed its edits" in b["body"])' "$GITEA/created.jsonl")" True
remote_head="$(git -C "$TMP/origin.git" rev-parse refs/heads/feature/7-nightcrew)"
same "the launcher's commit names the agent and provider in trailers" \
  "$(git -C "$TMP/origin.git" log -1 --format='%(trailers:key=Agent-Pool-Agent,key=Agent-Pool-Provider,separator=|)' "$remote_head")" \
  "Agent-Pool-Agent: cursor|Agent-Pool-Provider: cursor"
same "the launcher's commit carries exactly the worker's edit" \
  "$(git -C "$TMP/origin.git" diff-tree --no-commit-id --name-only -r "$remote_head")" widget.txt
case "$OUT" in *"running the offline test suites"*"committing the worker's edits"*) ok "the suites ran before the commit" ;; *) bad "tests before commit" "$OUT" ;; esac
case "$(cat "$PROJECT/logs/runs/issue-7-tests.log" 2>/dev/null)" in *"ok   agent-pool/tests/verify-ok.sh"*) ok "the suites' output is kept in the tests log" ;;
  *) bad "tests log" "$(cat "$PROJECT/logs/runs/issue-7-tests.log" 2>&1)" ;; esac
same "the state file records the publication" "$(state_of 7)" "published ok"
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
                               "Shell(bash agent-pool/tests/verify-ok.sh)")),
      all(f"Shell(git {sub})" in deny for sub in ("push", "commit", "add")), any(d.startswith("Read(") and ".config/pulse" in d for d in deny),
      any(a.startswith("Shell(python3 -c") or a == "Shell(python3)" for a in allow),
      "Shell(bash agent-pool/tests/verify-widget.sh)" in allow and not any("etc/verify-x" in a for a in allow))
PY
)"
same "cli.json: project adapter; tests and issue-named gates allowed; push, commit, add, credential reads, ../ paths denied" \
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
            "git add widget.txt", "git push origin HEAD", "bash -c id", "bash /tmp/x.sh", "python3 -c 1", "python3 x.py",
            "curl http://x", "sh x", "env"):
    print(cmd.split()[0] + ":" + decide(cmd), end=" ")
PY
)"
same "effective permissions: tests run; commit, add, push, shells, inline python, network denied" "$effective" \
  "bash:allow python3:allow python3:allow git:deny git:deny git:deny bash:deny bash:deny python3:deny python3:deny curl:deny sh:deny env:deny "
# The worker is edit-only: no prefix that stages, commits or pushes is allowed at all.
granted="$(python3 - "$STUB_STATE/cli.json" <<'PY'
import json, re, sys
allow = json.load(open(sys.argv[1]))["permissions"]["allow"]
print(" ".join(sorted(a for a in allow if re.match(r"Shell\(git (add|commit|push)", a))))
PY
)"
same "cli.json: no git add, commit or push prefix is allowed" "$granted" ""
case "$argv" in *"You are edit-only"*) ok "the prompt tells the worker it is edit-only" ;; *) bad "edit-only prompt" "missing" ;; esac
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
NIGHT_CREW_TASK_RECEIPT="$RECEIPT" STUB_MODE=edit run "$PROJECT" 7
same "rerun -> exit 0" "$CODE" 0
same "no second PR created" "$(created_count)" 1

echo
echo "a launcher step fails after the PR is open"
touch "$TMP/receipt-blocker"
NIGHT_CREW_TASK_RECEIPT="$TMP/receipt-blocker/job.json" STUB_MODE=edit run "$PROJECT" 7
same "a failed receipt write -> exit 1" "$CODE" 1
case "$OUT" in *"[night_shift] "*"ERROR line "*"failed with exit 1"*) ok "the failed step is logged by the launcher" ;; *) bad "failed step log" "$OUT" ;; esac
same "the lock file is removed after a failed step" "$( [ -e "$PROJECT/logs/night_shift.lock" ] && echo present || echo gone)" gone
same "the failed step is recorded" "$(state_of 7)" "failed launcher-step"

echo
echo "remote branch moved on"
SIDE="$TMP/side"
git clone -q "$TMP/origin.git" "$SIDE"
git -C "$SIDE" checkout -q feature/7-nightcrew
echo fix > "$SIDE/review-fix.txt"
git -C "$SIDE" add review-fix.txt
git -C "$SIDE" commit -qm "review fix"
git -C "$SIDE" push -q origin feature/7-nightcrew
STUB_MODE=noedit run "$PROJECT" 7
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
STUB_MODE=edit run "$PROJECT" 7
same "diverged local and remote branches -> exit 1" "$CODE" 1
case "$OUT" in *"have diverged"*) ok "divergence is reported before the agent runs" ;; *) bad "divergence" "$OUT" ;; esac
same "no agent ran on a diverged branch" "$( [ -e "$STUB_STATE/argv" ] && echo ran || echo none)" none

echo
echo "PR creation fails after the push: the published branch is kept for a rerun"
before="$(created_count)"
touch "$GITEA/post-fails"
NIGHT_CREW_TASK_RECEIPT="$TMP/receipts/issue-8.json" STUB_MODE=edit run "$PROJECT" 8
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
NIGHT_CREW_TASK_RECEIPT="$TMP/receipts/issue-8.json" STUB_MODE=noedit run "$PROJECT" 8
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
NIGHT_CREW_TASK_RECEIPT="$TMP/receipts/issue-9.json" STUB_MODE=edit run "$PROJECT" 9
rm -f "$GITEA/post-lost"
same "a lost PR creation response -> exit 1" "$CODE" 1
head9="$(git -C "$PROJECT" rev-parse feature/9-nightcrew 2>/dev/null)"
case "$OUT" in *"ERROR could not open or confirm a PR for feature/9-nightcrew at ${head9}"*) ok "the lost response is logged with the branch and head" ;;
  *) bad "lost response log" "$OUT" ;; esac
same "no receipt while the PR is unconfirmed" "$( [ -e "$TMP/receipts/issue-9.json" ] && echo written || echo none)" none
same "the branch stays on the remote" "$(git -C "$TMP/origin.git" rev-parse refs/heads/feature/9-nightcrew 2>/dev/null)" "$head9"
same "the server did create the PR" "$(created_count)" "$((before + 1))"
NIGHT_CREW_TASK_RECEIPT="$TMP/receipts/issue-9.json" STUB_MODE=noedit run "$PROJECT" 9
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
NIGHT_CREW_TASK_RECEIPT="$TMP/receipts/issue-10.json" STUB_MODE=edit run "$PROJECT" 10
same "a fork's, another base's or a baseless PR with the same branch name is not reused -> exit 0" "$CODE" 0
same "a PR of its own is opened" "$(created_count)" "$((before + 1))"
same "the receipt names the new PR, not a look-alike" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pr_number"])' "$TMP/receipts/issue-10.json" 2>&1)" \
  "$((99 + before))"

echo
echo "a created PR that does not match the branch is not trusted"
before="$(created_count)"
touch "$GITEA/post-mismatch"
NIGHT_CREW_TASK_RECEIPT="$TMP/receipts/issue-11.json" STUB_MODE=edit run "$PROJECT" 11
rm -f "$GITEA/post-mismatch"
same "a mismatched creation answer -> exit 1" "$CODE" 1
same "no receipt for an unverified PR" "$( [ -e "$TMP/receipts/issue-11.json" ] && echo written || echo none)" none
same "the branch stays on the remote for the rerun" "$(remote_has_branch feature/11-nightcrew)" yes

echo
echo "edit-only: the launcher commits every edit with agent and provider trailers"
before="$(created_count)"
start12="$(git -C "$TMP/origin.git" rev-parse refs/heads/master)"
NIGHT_CREW_TASK_RECEIPT="$TMP/receipts/issue-12.json" STUB_MODE=editmany run "$PROJECT" 12
same "new, nested and modified files -> exit 0" "$CODE" 0
same "the branch is pushed" "$(remote_has_branch feature/12-nightcrew)" yes
same "one PR opened" "$(created_count)" "$((before + 1))"
head12="$(git -C "$TMP/origin.git" rev-parse refs/heads/feature/12-nightcrew 2>/dev/null)"
same "exactly one commit, on the run's start" \
  "$(git -C "$TMP/origin.git" rev-list --parents -n 1 "$head12" 2>/dev/null)" "$head12 $start12"
same "the commit carries every edited file" \
  "$(git -C "$TMP/origin.git" diff-tree --no-commit-id --name-only -r "$head12" 2>/dev/null | tr '\n' ' ')" "AGENTS.md src/one.txt two.txt "
case "$(git -C "$TMP/origin.git" log -1 --format=%s "$head12" 2>/dev/null)" in
  *"#12"*) ok "the commit message names the issue" ;; *) bad "commit message" "$(git -C "$TMP/origin.git" log -1 --format=%s "$head12" 2>&1)" ;; esac
same "Agent-Pool-Agent names the agent" \
  "$(git -C "$TMP/origin.git" log -1 --format='%(trailers:key=Agent-Pool-Agent,valueonly)' "$head12" 2>/dev/null | head -n 1)" cursor
same "Agent-Pool-Provider names the provider" \
  "$(git -C "$TMP/origin.git" log -1 --format='%(trailers:key=Agent-Pool-Provider,valueonly)' "$head12" 2>/dev/null | head -n 1)" cursor
same "the receipt names the PR, the branch and the pushed head" \
  "$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["pr_number"], r["branch"], r["head"])' "$TMP/receipts/issue-12.json" 2>&1)" \
  "$((99 + before)) feature/12-nightcrew $head12"
same "the fully committed worktree is removed" "$( [ -d "$PROJECT/logs/worktrees/issue-12" ] && echo present || echo gone)" gone
NIGHT_CREW_TASK_RECEIPT="$TMP/receipts/issue-12-rerun.json" STUB_MODE=noedit run "$PROJECT" 12
same "a rerun without edits re-tests and reuses the launcher's commit and the open PR -> exit 0" "$CODE" 0
case "$OUT" in *"no new edits; testing the 1 commit(s)"*) ok "the rerun tested the earlier commit before publishing" ;; *) bad "rerun tests" "$OUT" ;; esac
same "no second PR for the rerun" "$(created_count)" "$((before + 1))"
same "the rerun did not rewrite the branch" "$(git -C "$TMP/origin.git" rev-parse refs/heads/feature/12-nightcrew)" "$head12"

echo
echo "edit-only: tool configuration is never committed"
STUB_MODE=edittoolconfig run "$PROJECT" 13
WT13="$PROJECT/logs/worktrees/issue-13"
same "edits beside tool configuration -> exit 0" "$CODE" 0
same "only the ordinary file is published" \
  "$(git -C "$TMP/origin.git" diff-tree --no-commit-id --name-only -r refs/heads/feature/13-nightcrew 2>/dev/null | tr '\n' ' ')" "kept.txt "
same "the worktree with the uncommitted tool configuration is kept" "$( [ -d "$WT13" ] && echo present || echo gone)" present
case "$OUT" in *"kept"*"$WT13"*) ok "the kept worktree's path is logged" ;; *) bad "kept worktree log" "$OUT" ;; esac
drop_issue 13

echo
echo "edit-only: a worker commit that got past the policy is refused"
before="$(created_count)"
STUB_MODE=workercommit run "$PROJECT" 16
WT16="$PROJECT/logs/worktrees/issue-16"
same "a worker commit -> exit 1" "$CODE" 1
same "it is recorded as a policy violation" "$(state_of 16)" "failed worker-committed"
same "the local branch is back on the base" "$(on_base 16)" yes
same "the worker's change is kept staged for a human" "$(git -C "$WT16" diff --cached --name-only 2>/dev/null)" rogue.txt
same "nothing pushed for it" "$(remote_has_branch feature/16-nightcrew)" no
same "no PR opened for it" "$(created_count)" "$before"
drop_issue 16

echo
echo "fail closed: the repository's tests fail on the worker's edits"
before="$(created_count)"
STUB_MODE=breaktests run "$PROJECT" 17
WT17="$PROJECT/logs/worktrees/issue-17"
same "a failing suite -> exit 1" "$CODE" 1
case "$OUT" in *"FAILED tests-failed:"*) ok "the test failure is logged by name" ;; *) bad "tests-failed log" "$OUT" ;; esac
same "the state file records the test failure" "$(state_of 17)" "failed tests-failed"
case "$(state_message 17)" in *"issue-17-tests.log"*) ok "the state file's message points at the tests log" ;; *) bad "tests-failed message" "$(state_message 17)" ;; esac
case "$(cat "$PROJECT/logs/runs/issue-17-tests.log" 2>/dev/null)" in *"FAIL agent-pool/tests/verify-broken.sh"*) ok "the tests log names the failing suite" ;;
  *) bad "tests log" "$(cat "$PROJECT/logs/runs/issue-17-tests.log" 2>&1)" ;; esac
same "nothing committed on the local branch" "$(on_base 17)" yes
same "nothing pushed" "$(remote_has_branch feature/17-nightcrew)" no
same "no PR opened" "$(created_count)" "$before"
same "the edits are kept in the worktree for a human" "$(cat "$WT17/widget.txt" 2>/dev/null)" widget
drop_issue 17
STUB_MODE=deletetests run "$PROJECT" 18
same "deleting every suite -> exit 1" "$CODE" 1
same "no suite to run is a test failure" "$(state_of 18)" "failed tests-failed"
same "nothing committed when no suite ran" "$(on_base 18)" yes
same "nothing pushed when no suite ran" "$(remote_has_branch feature/18-nightcrew)" no
drop_issue 18

echo
echo "a failed or parked run never discards the worker's edits"
STUB_MODE=editfail run "$PROJECT" 14
WT14="$PROJECT/logs/worktrees/issue-14"
same "edits then an agent failure -> exit 1" "$CODE" 1
same "it is recorded as an agent failure" "$(state_of 14)" "failed agent-failed"
same "nothing committed for a failure" "$(on_base 14)" yes
same "nothing pushed for a failure" "$(remote_has_branch feature/14-nightcrew)" no
same "the worktree with the edits is kept" "$(cat "$WT14/edited.txt" 2>/dev/null)" edited
case "$OUT" in *"kept"*"$WT14"*) ok "the kept worktree's path is logged" ;; *) bad "kept worktree log" "$OUT" ;; esac
same "the lock file is removed" "$( [ -e "$PROJECT/logs/night_shift.lock" ] && echo present || echo gone)" gone
before="$(created_count)"
STUB_MODE=editlimit run "$PROJECT" 15
same "edits then a provider limit -> exit 75" "$CODE" 75
same "nothing pushed for a limit" "$(remote_has_branch feature/15-nightcrew)" no
same "the parked run's tested edits are committed on the local branch" \
  "$(git -C "$PROJECT" diff-tree --no-commit-id --name-only -r feature/15-nightcrew 2>/dev/null)" edited.txt
same "with the agent and provider trailers" \
  "$(git -C "$PROJECT" log -1 --format='%(trailers:key=Agent-Pool-Provider,valueonly)' feature/15-nightcrew 2>/dev/null | head -n 1)" cursor
same "so its worktree is clean and removed" "$( [ -d "$PROJECT/logs/worktrees/issue-15" ] && echo present || echo gone)" gone
NIGHT_CREW_TASK_RECEIPT="$TMP/receipts/issue-15.json" STUB_MODE=noedit run "$PROJECT" 15
same "the requeued run starts and publishes the parked work -> exit 0" "$CODE" 0
same "the parked work reaches the remote" \
  "$(git -C "$TMP/origin.git" diff-tree --no-commit-id --name-only -r refs/heads/feature/15-nightcrew 2>/dev/null)" edited.txt
same "one PR opened for it" "$(created_count)" "$((before + 1))"
same "the requeued run's PR body names the launcher's park commit" \
  "$(python3 -c 'import json,sys; b=json.loads(open(sys.argv[1]).readlines()[-1]); print(("the launcher committed its edits after the offline test suites passed: " + sys.argv[2]) in b["body"])' \
    "$GITEA/created.jsonl" "$(git -C "$TMP/origin.git" rev-parse --short refs/heads/feature/15-nightcrew)" 2>&1)" True
STUB_MODE=breaklimit run "$PROJECT" 19
same "edits that fail the suites then a provider limit -> still exit 75" "$CODE" 75
same "the park is recorded" "$(state_of 19)" "parked limit"
same "nothing committed for a parked run whose suites fail" "$(on_base 19)" yes
same "its edits are kept in the worktree" "$(cat "$PROJECT/logs/worktrees/issue-19/edited.txt" 2>/dev/null)" edited
drop_issue 19

echo
echo "the launcher refuses a cli.json that is not edit-only"
python3 - "$PROJECT/agent-pool/scripts/policy.py" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
assert '"edit": CURSOR_EDIT_DENY' in text
open(path, "w").write(text.replace('"edit": CURSOR_EDIT_DENY', '"edit": []'))
PY
git -C "$PROJECT" commit -qam "weaken the edit policy"
rm -f "$STUB_STATE/argv"
STUB_MODE=edit run "$PROJECT" 20
same "a policy without the git add/commit denies -> exit 1" "$CODE" 1
case "$OUT" in *"refusing a cli.json that is not edit-only"*) ok "the refusal names the reason" ;; *) bad "cli.json refusal" "$OUT" ;; esac
same "no agent ran under it" "$( [ -e "$STUB_STATE/argv" ] && echo ran || echo none)" none
same "the refusal is recorded" "$(state_of 20)" "failed launcher-step"
git -C "$PROJECT" reset -q --hard HEAD~1
drop_issue 20

echo
echo "maintenance"
OUT="$(bash "$MAINT" "$PROJECT" unknown 2>&1)"; CODE=$?
same "unknown maintenance task -> exit 2" "$CODE" 2
OUT="$(bash "$MAINT" "$PROJECT" 2>&1)"; CODE=$?
same "missing maintenance task -> exit 2" "$CODE" 2
OUT="$(AGENT_POOL_MAIN=/leaked bash "$MAINT" "$PROJECT" quality 2>&1)"; CODE=$?
same "quality runs the offline suites without the caller's operator variables -> exit 0" "$CODE" 0
case "$OUT" in *"ok   agent-pool/tests/verify-ok.sh"*) ok "quality ran the verify suite" ;; *) bad "quality output" "$OUT" ;; esac
git init -q "$TMP/nosuites"
OUT="$(bash "$MAINT" "$TMP/nosuites" quality 2>&1)"; CODE=$?
same "quality with no suite to run -> exit 1" "$CODE" 1
case "$OUT" in *"FAIL no offline verify suite found"*) ok "quality says no suite was found" ;; *) bad "no-suite output" "$OUT" ;; esac

echo
echo "the worker inherits no controller authority (#25)"
rm -f "$STUB_STATE"/worker-* "$STUB_STATE/suite-fd9"
GITEA_TOKEN="$SECRET" NIGHT_CREW_TASK_RECEIPT="$TMP/receipts/issue-25.json" NIGHT_CREW_TOKEN_FILE="$TMP/crew_token" \
  SSH_AUTH_SOCK="$TMP/agent.sock" STUB_MODE=probe run "$PROJECT" 25
same "a contained worker run still publishes -> exit 0" "$CODE" 0
same "the worker sees no Gitea token, token file, task receipt, NightCrew token file or ssh-agent" \
  "$(tr '\n' ' ' < "$STUB_STATE/worker-env" 2>/dev/null)" \
  "GITEA_TOKEN=unset NIGHT_SHIFT_GITEA_TOKEN_FILE=unset NIGHT_CREW_TASK_RECEIPT=unset NIGHT_CREW_TOKEN_FILE=unset SSH_AUTH_SOCK=unset "
same "the worker does not hold the shift lock's fd 9" "$(cat "$STUB_STATE/worker-fd9" 2>/dev/null)" closed
same "a git push from the worker's worktree fails" "$(cat "$STUB_STATE/worker-push" 2>/dev/null)" refused
same "and reaches nothing on the remote" "$(remote_has_branch worker-push)" no
same "the suites the launcher runs on the worker's edits do not hold fd 9 either" \
  "$(cat "$STUB_STATE/suite-fd9" 2>/dev/null)" closed
same "the launcher still pushes the branch itself" "$(remote_has_branch feature/25-nightcrew)" yes
same "and writes the receipt the worker could not see" \
  "$( [ -s "$TMP/receipts/issue-25.json" ] && echo written || echo none)" written
drop_issue 25
git -C "$PROJECT" config remote.origin.pushurl "$TMP/origin.git"
rm -f "$STUB_STATE/argv"
STUB_MODE=probe run "$PROJECT" 25
git -C "$PROJECT" config --unset remote.origin.pushurl
same "a configured pushurl the override cannot replace -> exit 1" "$CODE" 1
case "$OUT" in *"remote.origin.pushurl is configured"*) ok "the refusal names the pushurl" ;; *) bad "pushurl refusal" "$OUT" ;; esac
case "$OUT" in *"launching cursor-agent"*) bad "the refusal is not logged as a launch" "$OUT" ;; *) ok "the refusal is not logged as a launch" ;; esac
same "no agent ran with a pushurl configured" "$( [ -e "$STUB_STATE/argv" ] && echo ran || echo none)" none
same "nothing pushed with a pushurl configured" "$(remote_has_branch worker-push)" no
drop_issue 25

echo
echo "nothing secret is printed"
if grep -qF -- "$SECRET" "$ALL_OUTPUT" "$PROJECT/logs/night_shift_agent.log"; then bad "the token never appears in output" "found"
else ok "the token never appears in output"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
