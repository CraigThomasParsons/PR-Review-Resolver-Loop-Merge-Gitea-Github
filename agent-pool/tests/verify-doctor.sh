#!/usr/bin/env bash
# Offline cases for the agent pool's doctor (agent-pool/bin/doctor.sh, scripts/doctor.py).
#
# Everything is stubbed: HOME is a temp directory whose .local/bin holds stub claude,
# cursor-agent, grok, agy and codex CLIs that only record that they were called, the Gitea
# adapter is a stub keeping PR labels and comments in a JSON file, and repos.toml, the state
# directory and the clock are the test's own. No provider CLI, no network, no systemctl.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCTOR="$ROOT/agent-pool/bin/doctor.sh"
CLAIMREC="$ROOT/agent-pool/scripts/claim-record.py"
COOLDOWN="$ROOT/agent-pool/scripts/cooldown.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
BIN="$HOME/.local/bin"
mkdir -p "$BIN" "$TMP/common"
export PATH="$BIN:$PATH"
R=owner/repo
SHA_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHA_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# ---------------------------------------------------------------- stubs
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
if os.path.exists(path + ".fail-" + cmd):
    sys.exit(f"stub adapter: {cmd} failed")
if cmd == "list":
    print(json.dumps([{"number": int(n), "title": p.get("title", "t"), "draft": p.get("draft", False),
                       "head_sha": p["head_sha"], "head_ref": "feature/x", "base_ref": "master", "author": "human",
                       "is_bot": False, "labels": p["labels"], "assignees": p.get("assignees", []), "url": ""}
                      for n, p in st["prs"].items() if p.get("repo", arg("--repo")) == arg("--repo")]))
elif cmd == "labels":
    print(json.dumps(st["prs"][arg("--pr")]["labels"]))
elif cmd == "state":
    p = st["prs"][arg("--pr")]
    if os.path.exists(path + ".race"):
        # Someone acted between the doctor's listing and its relabel.
        p.update(json.load(open(path + ".race"))); os.remove(path + ".race"); save()
    print(json.dumps({"head_sha": p["head_sha"], "labels": p["labels"], "assignees": p.get("assignees", [])}))
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
cp "$ROOT/skills/pr-loops-common/marker.py" "$TMP/common/marker.py"
cat > "$BIN/stub-provider" <<'SH'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "$STUB_CALLS"
exit 99
SH
chmod +x "$BIN/stub-provider"
for cli in claude cursor-agent grok agy codex; do ln -s stub-provider "$BIN/$cli"; done

export STUB_GITEA="$TMP/gitea.json" STUB_CALLS="$TMP/provider-calls"
export AGENT_POOL_STATE="$TMP/state" AGENT_POOL_CONFIG="$TMP/repos.toml"
export AGENT_POOL_ADAPTER="$TMP/common/gitea-pr.py" AGENT_POOL_MARKER="$TMP/common/marker.py"
export PR_LOOP_SKIP_PATTERN=""
unset AGENT_POOL_NOW DOCTOR_DRY_RUN AGENT_POOL_BOT

# ---------------------------------------------------------------- harness
conf() { printf '%s\n' "$@" > "$AGENT_POOL_CONFIG"; }
reset() { # [config lines...]; empty queue, review-only owner/repo unless lines are given
  rm -rf "$TMP/state" "$STUB_GITEA".*
  echo '{"prs": {}}' > "$STUB_GITEA"
  if [ "$#" -gt 0 ]; then conf "$@"; else conf '[repos."owner/repo"]'; fi
}
addpr() { # pr labels-json [comments-json] [assignees-json] [head]
  python3 - "$STUB_GITEA" "$@" <<'PY'
import json, os, sys
path, pr, labels = sys.argv[1:4]
comments = sys.argv[4] if len(sys.argv) > 4 else "[]"
assignees = sys.argv[5] if len(sys.argv) > 5 else "[]"
head = sys.argv[6] if len(sys.argv) > 6 else "a" * 40
st = json.load(open(path))
st["prs"][pr] = {"head_sha": head, "labels": json.loads(labels), "assignees": json.loads(assignees),
                 "comments": json.loads(comments)}
if os.environ.get("PR_REPO"):
    st["prs"][pr]["repo"] = os.environ["PR_REPO"]
json.dump(st, open(path, "w"))
PY
}
review_marker() { # head findings
  printf '[{"id":1,"user":"bot","created_at":"","body":"## Automated review\\n<!-- pulse-review:v1 head=%s findings=%s -->"}]' "$1" "$2"
}
claim() { # pr provider worker [seconds-ago] [deadline-secs] -> attempt id
  local now; now="$(date +%s)"
  AGENT_POOL_NOW=$(( now - ${4:-0} )) python3 "$CLAIMREC" claim --repo "${CLAIM_REPO:-$R}" --pr "$1" --worker "$3" \
    --provider "$2" --job review --deadline-secs "${5:-2700}"
}
lockfile() { printf '%s/pool-%s-%s.lock' "$TMP/state" "$1" "$(printf '%s' "${2:-$R}" | tr -c 'A-Za-z0-9.-' '_')"; }
doctor() { bash "$DOCTOR" "$@" > "$TMP/report.json" 2> "$TMP/doctor.err"; DOC_RC=$?; }
rq() { python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$TMP/report.json" "$1" 2>&1; }
labels() { python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1]))["prs"][sys.argv[2]]["labels"]))' "$STUB_GITEA" "$1"; }
comments() { python3 "$AGENT_POOL_ADAPTER" comments --repo "$R" --pr "$1"; }
record() { python3 "$CLAIMREC" show --repo "${2:-$R}" --pr "$1"; }
writes() { cat "$STUB_GITEA.writes" 2>/dev/null; }
cooldown_doc() { cat "$TMP/state/cooldowns/$1.json" 2>/dev/null || echo none; }
snapshot() { (cd "$TMP/state" && find . -type f | LC_ALL=C sort) > "$TMP/$1"; }

pass=0; fail=0
expect() { # name got wanted-substring
  if [[ "$2" == *"$3"* ]]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n         wanted *%s*\n         got %s\n' "$1" "$3" "$2"
    sed 's/^/           | /' "$TMP/doctor.err" | tail -8; fi
}
expect_not() { # name got unwanted-substring
  if [[ "$2" != *"$3"* ]]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n         did not want *%s*\n         got %s\n' "$1" "$3" "$2"
    sed 's/^/           | /' "$TMP/doctor.err" | tail -8; fi
}

# ---------------------------------------------------------------- cases
echo "stale claims are fenced and requeued, never deleted"
reset
addpr 7 '["agent:claimed"]'
old="$(claim 7 grok w1 10000 100)"
snapshot before
doctor
expect "the doctor exits 0" "$DOC_RC" "0"
expect "the stale claim is reported stale" "$(rq 'r["claims"][0]["state"]')" "stale"
expect "and requeued" "$(rq 'r["claims"][0]["action"]')" "requeued"
expect "the PR is back in agent:ready" "$(labels 7)" "agent:ready"
expect_not "and no longer agent:claimed" "$(labels 7)" "agent:claimed"
expect "the record now names a fence by the doctor" "$(record 7)" '"worker_id": "doctor"'
expect "fencing the superseded attempt" "$(record 7)" "\"fenced_attempt\": \"$old\""
expect "with the epoch bumped" "$(record 7)" '"epoch": 1'
expect "and a fresh attempt id" "$(rq 'r["claims"][0]["fence_attempt"] != "'"$old"'" and len(r["claims"][0]["fence_attempt"]) == 36')" "True"
expect "the fenced record is archived" "$(cat "$TMP/state/claims/fenced/owner_repo__7.$old.json" 2>/dev/null)" "\"worker_id\": \"w1\""
python3 "$CLAIMREC" check --repo $R --pr 7 --attempt "$old" 2>/dev/null
expect "the superseded attempt is no longer current" "$?" "4"
python3 "$CLAIMREC" release --repo $R --pr 7 --attempt "$old" -- python3 "$AGENT_POOL_ADAPTER" label --repo $R --pr 7 \
  --remove agent:claimed --add agent:done 2>/dev/null
expect "so its late release is refused" "$?" "4"
expect "and the requeue stands" "$(labels 7)" "agent:ready"
expect "its provider is cooled down" "$(cooldown_doc grok)" '"strikes": 1'
snapshot after
expect "no file the doctor found is gone" "$(comm -23 "$TMP/before" "$TMP/after" | tr '\n' ' ')" ""
expect "the JSON report is written to the state dir" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["summary"])' "$TMP/state/doctor/report.json")" "'requeued': 1"
expect "the doctor logs what it did" "$(cat "$TMP/state/doctor.log")" "fenced and requeued to agent:ready"
out="$(python3 "$CLAIMREC" reconcile --repo $R --pr 7 --adapter "$AGENT_POOL_ADAPTER")"
expect "the next prod tick's reconcile drops the fence as already released" "$out" "orphan-dropped"
claim 7 claude w2 >/dev/null
expect "and the job can be claimed afresh" "$?" "0"

echo
echo "dry run"
reset
addpr 7 '["agent:claimed"]'
old="$(claim 7 grok w1 10000 100)"
snapshot before
doctor --dry-run
expect "--dry-run reports the stale claim" "$(rq 'r["claims"][0]["action"]')" "would-requeue"
expect "and says it is a dry run" "$(rq 'r["dry_run"]')" "True"
expect "but touches no label" "$(labels 7)" "agent:claimed"
expect "nor the claim" "$(record 7)" "\"attempt_id\": \"$old\""
expect "nor the cooldowns" "$(cooldown_doc grok)" "none"
expect "nor Gitea at all" "$(w="$(writes)"; echo "${w:-none}")" "none"
DOCTOR_DRY_RUN=1 doctor
expect "DOCTOR_DRY_RUN=1 is a dry run too" "$(rq 'r["claims"][0]["action"]')" "would-requeue"
doctor --dry-run --report "$TMP/elsewhere.json"
expect "--report writes the report where asked" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["dry_run"])' "$TMP/elsewhere.json")" "True"

echo
echo "dead workers: a claim whose tick is gone"
reset
addpr 7 '["agent:claimed"]'
old="$(claim 7 claude w1)"
: > "$(lockfile w1)"
doctor
expect "a live claim whose tick lock nobody holds is a dead worker" "$(rq 'r["claims"][0]["state"]')" "dead-worker"
expect "it is requeued before its deadline" "$(labels 7)" "agent:ready"
expect "under a fence" "$(record 7)" "\"fenced_attempt\": \"$old\""
expect "with no cooldown: the tick died, not the provider" "$(cooldown_doc claude)" "none"
reset
addpr 7 '["agent:claimed"]'
old="$(claim 7 claude w1)"
exec 8>"$(lockfile w1)"; flock -x 8
doctor
expect "a claim whose tick still holds its lock is live" "$(rq 'r["claims"][0]["state"]')" "live"
expect "and left alone" "$(labels 7)" "agent:claimed"
expect "with its record untouched" "$(record 7)" "\"attempt_id\": \"$old\""
exec 8>&-
reset
addpr 7 '["agent:claimed"]'
claim 7 claude w1 >/dev/null
doctor
expect "with no lock file at all, only the deadline counts" "$(rq 'r["claims"][0]["state"]')" "live"
expect "so a live claim stays claimed" "$(labels 7)" "agent:claimed"
expect "and the doctor never created the lock file" "$([ -e "$(lockfile w1)" ] && echo created || echo absent)" "absent"

echo
echo "published work and partial failures"
reset
addpr 7 '["agent:claimed"]'
old="$(claim 7 grok w1 10000 100)"
mkdir -p "$TMP/state/published"; : > "$TMP/state/published/owner_repo__7.$old"
doctor
expect "a stale claim whose work was published is requeued" "$(labels 7)" "agent:ready"
expect "with no cooldown" "$(cooldown_doc grok)" "none"
expect "and its published mark is left in place" "$(ls "$TMP/state/published")" "owner_repo__7.$old"
reset
addpr 7 '["agent:claimed"]'
old="$(claim 7 grok w1 10000 100)"
: > "$STUB_GITEA.fail-label"
doctor
expect "a failed requeue flip is an error (exit 1)" "$DOC_RC" "1"
expect "and reported" "$(rq 'r["errors"]')" "could not fence"
expect "the PR is still labelled agent:claimed" "$(labels 7)" "agent:claimed"
expect "the fence stands as a stale claim" "$(record 7)" "\"fenced_attempt\": \"$old\""
rm -f "$STUB_GITEA.fail-label"
fence1="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["attempt_id"])' <<<"$(record 7)")"
doctor
expect "the next pass fences the fence and requeues" "$(labels 7)" "agent:ready"
expect "both records are archived" "$(ls "$TMP/state/claims/fenced" | wc -l | tr -d ' ')" "2"
expect "the epoch keeps counting" "$(record 7)" '"epoch": 2'
expect "and the fence's empty provider costs nobody a strike" "$(cooldown_doc grok)" '"strikes": 1'
reset
addpr 7 '["agent:claimed"]'
claim 7 grok w1 10000 100 >/dev/null
: > "$STUB_GITEA.fail-list"
doctor
expect "a failed PR listing decides nothing for the repo" "$(labels 7)" "agent:claimed"
expect "and is an error" "$(rq 'r["errors"]')" "cannot list open PRs"

echo
echo "claimed with no record, and records with no claimed label"
reset
addpr 7 '["agent:claimed"]'
doctor
expect "agent:claimed with no record goes to agent:needs-human" "$(labels 7)" "agent:needs-human"
expect "with a comment saying why" "$(comments 7)" "no claim record backs it"
expect "reported as no-record" "$(rq 'r["claims"][0]["state"]')" "no-record"
reset
addpr 7 '["agent:done"]'
claim 7 claude w1 10000 100 >/dev/null
doctor
expect "a record whose PR is not claimed is an orphan" "$(rq 'r["claims"][0]["state"]')" "orphan"
expect "which the doctor leaves for the prod tick" "$(record 7)" '"worker_id": "w1"'
expect "touching no label" "$(labels 7)" "agent:done"

echo
echo "the queue: jobs nobody may take go to agent:needs-human"
reset
addpr 7 '["agent:ready"]'
addpr 8 '["agent:ready"]' "$(review_marker "$SHA_A" 2)"
doctor
expect "a review job on a review-only repo is claimable" "$(rq '[q["state"] for q in r["queue"] if q["pr"] == 7]')" "claimable"
expect "and left queued" "$(labels 7)" "agent:ready"
expect "a resolve job there is derived from the findings" "$(rq '[q["job"] for q in r["queue"] if q["pr"] == 8]')" "resolve"
expect "and reported not-enabled" "$(rq '[q["state"] for q in r["queue"] if q["pr"] == 8]')" "not-enabled"
expect "it goes to agent:needs-human" "$(labels 8)" "agent:needs-human"
expect_not "out of the queue" "$(labels 8)" "agent:ready"
expect "with a comment naming the ability" "$(comments 8)" "queued (\`agent:ready\`) for a resolve job, but resolve is not enabled on owner/repo"
reset
addpr 8 '["agent:ready"]' "$(review_marker "$SHA_A" 2)"
doctor --dry-run
expect "--dry-run only says it would escalate" "$(rq 'r["queue"][0]["action"]')" "would-needs-human"
expect "and leaves the label" "$(labels 8)" "agent:ready"
expect "and posts nothing" "$(comments 8)" "pulse-review"
expect_not "no doctor comment" "$(comments 8)" "doctor"
reset '[pool]' 'providers = ["agy"]' '[repos."owner/repo"]' 'abilities = ["review", "resolve"]'
addpr 7 '["agent:ready"]'
addpr 8 '["agent:ready"]' "$(review_marker "$SHA_A" 1)"
doctor
expect "an agy-only roster can review" "$(labels 7)" "agent:ready"
expect "but never resolve, so the resolve job needs a human" "$(labels 8)" "agent:needs-human"
expect "and agy is reported without resolve" "$(rq 'r["queue"][1]["providers"]["agy"]["abilities"]')" "['review']"
reset '[pool]' 'providers = ["claude"]' '[repos."owner/repo"]' 'abilities = ["review", "resolve"]'
addpr 8 '["agent:ready"]' "$(review_marker "$SHA_A" 1)"
rm "$BIN/claude"
doctor
expect "an enabled provider that is not installed cannot take the job" "$(rq 'r["queue"][0]["state"]')" "not-installed"
expect "so it needs a human" "$(labels 8)" "agent:needs-human"
ln -s stub-provider "$BIN/claude"
reset '[pool]' 'providers = ["claude"]' '[repos."owner/repo"]' 'abilities = ["review", "resolve"]'
addpr 8 '["agent:ready"]' "$(review_marker "$SHA_A" 1)"
python3 "$COOLDOWN" record --provider claude --reason test >/dev/null
doctor
expect "a job whose only provider is cooling down waits" "$(rq 'r["queue"][0]["state"]')" "waiting-cooldown"
expect "and stays queued" "$(labels 8)" "agent:ready"
reset '[pool]' 'providers = ["claude"]' '[repos."owner/repo"]' 'abilities = ["review", "resolve"]'
addpr 8 '["agent:ready"]' "$(review_marker "$SHA_A" 1)"
doctor
expect "with resolve enabled and claude installed the job is claimable" "$(rq 'r["queue"][0]["state"]')" "claimable"

echo "  (what the doctor leaves alone)"
reset
addpr 7 '["agent:ready"]' "$(review_marker "$SHA_A" 2)" '["craig"]'
addpr 8 '["agent:ready"]' "$(review_marker "$SHA_A" 0)"
addpr 9 '["agent:ready"]' "$(review_marker "$SHA_B" 2)"
doctor
expect "a human-assigned job is held, not escalated" "$(labels 7)" "agent:ready"
expect "and reported held" "$(rq '[q["state"] for q in r["queue"] if q["pr"] == 7]')" "held"
expect "a clean review at the head is settled, not escalated" "$(rq '[q["state"] for q in r["queue"] if q["pr"] == 8]')" "settled"
expect "a review of an older head means a review job" "$(rq '[q["job"] for q in r["queue"] if q["pr"] == 9]')" "review"
expect "so it is not escalated" "$(labels 9)" "agent:ready"
reset
addpr 8 '["agent:ready"]' "$(review_marker "$SHA_A" 2)"
claim 8 claude w1 >/dev/null
doctor
expect "a ready PR with a claim record in flight is not swept" "$(rq 'len(r["queue"])')" "0"
expect "and keeps its label" "$(labels 8)" "agent:ready"
reset
addpr 8 '["agent:ready"]' "$(review_marker "$SHA_A" 2)"
echo '{"head_sha": "cccccccccccccccccccccccccccccccccccccccc"}' > "$STUB_GITEA.race"
doctor
expect "a head that moved before the escalation refuses it" "$(labels 8)" "agent:ready"
expect "reported as skipped, not failed" "$(rq 'r["queue"][0]["action"]')" "skipped"
expect "with the reason" "$(rq 'r["queue"][0]["reason"]')" "the head moved"
expect "which is not an error" "$DOC_RC" "0"

echo
echo "allowlist, config and the never-an-LLM rule"
reset '[repos."owner/configured"]'
PR_REPO=owner/unlisted addpr 7 '["agent:claimed"]'
CLAIM_REPO=owner/unlisted claim 7 grok w1 10000 100 >/dev/null
doctor
expect "a stale claim on a repo not in repos.toml is reported" "$(rq 'r["claims"][0]["state"]')" "stale"
expect "but only reported" "$(rq 'r["claims"][0]["action"]')" "report-only"
expect "its record is untouched" "$(record 7 owner/unlisted)" '"worker_id": "w1"'
expect "and its label" "$(labels 7)" "agent:claimed"
reset '[repos."owner/repo"]' 'abilities = ["reveiw"]'
addpr 7 '["agent:claimed"]'
claim 7 grok w1 10000 100 >/dev/null
doctor
expect "an unusable config exits 2" "$DOC_RC" "2"
expect "decides nothing" "$(labels 7)" "agent:claimed"
expect "and says why in the report" "$(rq 'r["errors"]')" "unknown ability 'reveiw'"
reset
mkdir -p "$TMP/state"
exec 8>"$TMP/state/doctor.lock"; flock -x 8
doctor
expect "a second doctor tick exits quietly while one runs" "$DOC_RC" "0"
expect "and says so" "$(cat "$TMP/doctor.err")" "previous doctor tick still running"
exec 8>&-
expect "no provider CLI was ever invoked by the doctor" "$(cat "$STUB_CALLS" 2>/dev/null || echo none)" "none"
expect_not "doctor.sh names no provider binary" "$(grep -Ev '^\s*#' "$DOCTOR")" "claude"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
