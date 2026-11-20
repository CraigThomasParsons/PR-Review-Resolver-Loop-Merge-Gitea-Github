#!/usr/bin/env bash
# pr-update.sh: bring every open PR into a repo's integration branch up to date with it.
#
# After a PR merges to develop, every other open PR targeting develop is behind it. One tick, one
# repo, one PR at a time:
#
#   1. merge develop into the PR branch (a merge commit, never a rebase: reviewed history stays)
#   2. on a conflict small enough (PR_UPDATE_MAX_CONFLICT_FILES / _LINES), let the AI conflict
#      resolver (PR_UPDATE_RESOLVER, default pr-update-resolve.sh) edit the conflicted files, then
#      check it left no markers and touched nothing else
#   3. run the repo's own gates (the agent pool's pinned manifest, agent-pool/scripts/gates.py,
#      in its sandbox) against the merged commit
#   4. push it to the PR branch as a plain fast-forward (never a force push), and relabel the PR
#      review:requested so it gets a fresh review
#   A red gate, a conflict too large, a resolver that fails or a resolution touching anything but
#   the conflicted files sets review:needs-human with a comment instead, and nothing is pushed.
#
# Idempotent: a PR whose head already contains develop's tip is skipped, so the tick can run after
# every merge (pr-merge.sh calls it), on a timer, or by hand, and catches merges made by people in
# the Gitea UI the same way. Never merges a PR, never force-pushes, never touches develop itself.
#
# Skipped, untouched: drafts, bot PRs, PRs based elsewhere, PRs from forks (head not in this
# repo), protected or odd head branches, and PRs someone is working on or a human must look at
# (review:needs-human, review:in-progress, review:resolving, review:merging, agent:claimed,
# agent:needs-human).
#
# Environment (all optional unless marked):
#   PR_LOOP_REPO (required)        owner/name on Gitea
#   PR_LOOP_MAIN                   the repo's main clone (default: the NightCrew registry's
#                                  project_dir, else ~/Code/<name>, as pr-pipeline.sh resolves it)
#   PR_LOOP_REMOTE=origin          the remote carrying the PR branches
#   PR_UPDATE_BASE=develop         the integration branch PRs target
#   PR_LOOP_PR=N                   consider only PR #N
#   DRY_RUN=1                      list what would happen; write nothing
#   PR_UPDATE_MAX_CONFLICT_FILES=5 PR_UPDATE_MAX_CONFLICT_LINES=200   above either: needs-human
#   PR_UPDATE_RESOLVER             conflict resolver command (default pr-update-resolve.sh beside
#                                  this file); set it empty to send every conflict to a human
#   PR_UPDATE_RESOLVER_TIMEOUT=1800
#   PR_UPDATE_REQUIRE_GATES=0      1: a code change with no gate manifest is needs-human instead
#                                  of pushed untested (an AI-resolved conflict always needs gates)
#   PR_UPDATE_GATE_BUDGET=1200     seconds for the gate run
#   PR_LOOP_POOL_ROOT              the checkout holding agent-pool/ (default: the "source" in
#                                  COMMON/.deployed-from when it holds agent-pool/scripts/gates.py,
#                                  else two levels above this file's real path)
#   AGENT_POOL_STATE               the pool's state (gate cache and gate lock are shared with it)
#   PR_LOOP_STATE                  lock and log (default ~/.local/state/gitea-pr-loops)
#   PR_UPDATE_WORKTREES            scratch worktrees (default .prupdate-worktrees beside the clone)
#
# Exit codes: 0 for a normal tick (including nothing to do); 2 for a setup fault.

set -uo pipefail

if [ -z "${PR_UPDATE_PINNED:-}" ]; then
  PR_UPDATE_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  PR_UPDATE_REAL="$(readlink -f -- "${BASH_SOURCE[0]}")"
  export PR_UPDATE_HOME PR_UPDATE_REAL
  pinned="$(mktemp -t pr-update.XXXXXX.sh)"
  cp "${BASH_SOURCE[0]}" "$pinned"
  export PR_UPDATE_PINNED="$pinned"
  bash "$pinned" "$@"
  rc=$?
  rm -f "$pinned"
  exit $rc
fi

COMMON="$PR_UPDATE_HOME"
ADAPTER="${PR_UPDATE_ADAPTER:-$COMMON/gitea-pr.py}"
REPO="${PR_LOOP_REPO:-}"
REMOTE="${PR_LOOP_REMOTE:-origin}"
BASE="${PR_UPDATE_BASE:-develop}"
ONLY_PR="${PR_LOOP_PR:-}"
DRY_RUN="${DRY_RUN:-0}"
STATE="${PR_LOOP_STATE:-$HOME/.local/state/gitea-pr-loops}"
LOG="$STATE/pr-loop.log"
MAX_FILES="${PR_UPDATE_MAX_CONFLICT_FILES:-5}"
MAX_LINES="${PR_UPDATE_MAX_CONFLICT_LINES:-200}"
RESOLVER="${PR_UPDATE_RESOLVER-$COMMON/pr-update-resolve.sh}"
RESOLVER_TIMEOUT="${PR_UPDATE_RESOLVER_TIMEOUT:-1800}"
REQUIRE_GATES="${PR_UPDATE_REQUIRE_GATES:-0}"
GATE_BUDGET="${PR_UPDATE_GATE_BUDGET:-1200}"
POOL_STATE="${AGENT_POOL_STATE:-$HOME/.local/state/agent-pool}"
# A deployed copy (install.sh) is a plain directory under ~/.claude/skills with no agent-pool/
# beside it, so prefer the checkout its .deployed-from names when that path has the gate runner;
# otherwise two levels above this file's real path (a checkout, or a symlink to one).
POOL_ROOT="${PR_LOOP_POOL_ROOT:-}"
if [ -z "$POOL_ROOT" ]; then
  POOL_ROOT="$(awk '$1=="source" {sub(/^source /, ""); print; exit}' "$COMMON/.deployed-from" 2>/dev/null || true)"
  [ -n "$POOL_ROOT" ] && [ -f "$POOL_ROOT/agent-pool/scripts/gates.py" ] \
    || POOL_ROOT="$(cd -- "$(dirname -- "$PR_UPDATE_REAL")/../.." 2>/dev/null && pwd)"
fi
GATES="$POOL_ROOT/agent-pool/scripts/gates.py"
PROTECTED="${AGENT_POOL_PROTECTED_BRANCHES:-develop,main,master,release}"
NEEDS_HUMAN="review:needs-human"
REQUESTED="review:requested"
# Labels that say the reviewed state of the old head; a new head makes them stale.
STALE_RESULT="review:findings,review:clean,review:resolved,agent:done"
# Someone is working on the PR, or a human has to: leave it alone.
BUSY='review:needs-human review:in-progress review:resolving review:merging agent:claimed agent:needs-human'

mkdir -p "$STATE"
log() { printf '%s [update] [%s] %s\n' "$(date -Is)" "$REPO" "$*" | tee -a "$LOG" >&2; }
die() { log "FATAL: $*"; exit 2; }

[ -n "$REPO" ] || die "PR_LOOP_REPO is required"
[ -z "$ONLY_PR" ] || [[ "$ONLY_PR" =~ ^[1-9][0-9]*$ ]] || die "PR_LOOP_PR must be a PR number (got '$ONLY_PR')"
for knob in MAX_FILES MAX_LINES RESOLVER_TIMEOUT GATE_BUDGET; do
  [[ "${!knob}" =~ ^[0-9]+$ ]] || die "PR_UPDATE_${knob} must be a whole number (got '${!knob}')"
done
[ -f "$ADAPTER" ] || die "missing Gitea adapter: $ADAPTER"

# The same lookup pr-pipeline.sh uses: the NightCrew registry, then ~/Code/<name>.
MAIN="${PR_LOOP_MAIN:-}"
if [ -z "$MAIN" ]; then
  MAIN="$(python3 - "$REPO" <<'PYEOF' 2>/dev/null
import json, os, sys
try:
    registry = json.load(open(os.path.expanduser("~/.config/pulse/night_crew_repositories.json")))
except Exception:
    registry = {}
print((registry.get(sys.argv[1]) or {}).get("project_dir", ""))
PYEOF
)"
  [ -n "$MAIN" ] || MAIN="$HOME/Code/${REPO##*/}"
fi
[ -e "$MAIN/.git" ] || die "no checkout for $REPO: set PR_LOOP_MAIN (got '$MAIN')"
WT_ROOT="${PR_UPDATE_WORKTREES:-$(dirname "$MAIN")/.prupdate-worktrees}"
mkdir -p "$WT_ROOT"

exec 9>"$STATE/update-${REPO//\//__}.lock"
if ! flock -n 9; then log "previous update tick for $REPO still running; exiting"; exit 0; fi

git -C "$MAIN" fetch "$REMOTE" --quiet --prune || die "fetch from $REMOTE failed; not updating against a stale $BASE"
BASE_SHA="$(git -C "$MAIN" rev-parse --verify -q "refs/remotes/$REMOTE/$BASE^{commit}")" \
  || die "cannot resolve $REMOTE/$BASE in $MAIN"

if ! LISTING="$(python3 "$ADAPTER" list --repo "$REPO" --state open | BASE="$BASE" ONLY_PR="$ONLY_PR" BUSY="$BUSY" python3 -c '
import json, os, re, sys
base, only, busy = os.environ["BASE"], os.environ.get("ONLY_PR", ""), set(os.environ["BUSY"].split())
skip = re.compile(os.environ.get("PR_LOOP_SKIP_PATTERN", r"docblock-backfill|^chore\(#152\)") or "$^")
for pr in json.load(sys.stdin):
    if only and str(pr["number"]) != only: continue
    if pr["base_ref"] != base or pr["draft"] or pr["is_bot"]: continue
    if skip.search(pr["title"]) or skip.search(pr["head_ref"]): continue
    held = sorted(busy & set(pr["labels"]))
    print("\t".join([str(pr["number"]), pr["head_ref"], pr["head_sha"], ",".join(held) or "-"]))
')"; then
  die "gitea pr list failed; not treating that as an empty queue"
fi
mapfile -t CANDIDATES < <(printf '%s\n' "$LISTING" | sed '/^$/d')
[ "${#CANDIDATES[@]}" -eq 0 ] && { log "no open PR targets $BASE"; exit 0; }

headref_safe() { # headref
  local h="$1" b prot
  case "$h" in ""|+*|-*|*:*|refs/*|release/*|*..*) return 1 ;; esac
  IFS=, read -ra prot <<<"$PROTECTED"
  for b in "${prot[@]}"; do [ "$h" = "$b" ] && return 1; done
  git -C "$MAIN" check-ref-format --branch "$h" >/dev/null 2>&1
}

comment() { # pr body
  local bf; bf="$(mktemp)"; printf '%s\n' "$2" > "$bf"
  python3 "$ADAPTER" comment --repo "$REPO" --pr "$1" --body-file "$bf" >/dev/null 2>&1 || log "warning: comment on #$1 failed"
  rm -f "$bf"
}
# relabel pr add remove-candidates: removes only the candidates the PR carries.
relabel() {
  local pr="$1" add="$2" current remove="" l
  current="$(python3 "$ADAPTER" labels --repo "$REPO" --pr "$pr" 2>/dev/null)" || current=""
  IFS=, read -ra cand <<<"$3"
  for l in "${cand[@]}"; do [[ "$current" == *"\"$l\""* ]] && remove="${remove:+$remove,}$l"; done
  python3 "$ADAPTER" label --repo "$REPO" --pr "$pr" --add "$add" ${remove:+--remove "$remove"} >/dev/null 2>&1 \
    || { log "warning: relabel of #$pr (+$add${remove:+ -$remove}) failed"; return 1; }
}
needs_human() { # pr why
  log "#$1: $NEEDS_HUMAN: $2"
  [ "$DRY_RUN" = 1 ] && return 0
  relabel "$1" "$NEEDS_HUMAN" "$REQUESTED"
  comment "$1" "Automated update from \`$BASE\` stopped: $2. Nothing was pushed; the branch is as it was. A human needs to bring it up to date."
}

WT=""; GATE_DIR=""
cleanup_pr() {
  if [ -n "$WT" ]; then
    git -C "$WT" merge --abort >/dev/null 2>&1
    git -C "$MAIN" worktree remove --force "$WT" >/dev/null 2>&1 || log "worktree $WT kept; remove it by hand"
  fi
  if [ -n "$GATE_DIR" ]; then chmod -R u+w "$GATE_DIR" 2>/dev/null; rm -rf "$GATE_DIR" "$GATE_DIR.index"; fi
  WT=""; GATE_DIR=""
}
trap cleanup_pr EXIT

# conflict_lines: lines inside conflict regions across the conflicted files, markers included.
conflict_lines() {
  local f total=0 n
  while IFS= read -r -d '' f; do
    n="$(awk '/^<<<<<<< /{inside=1} inside{c++} /^>>>>>>> /{inside=0} END{print c+0}' "$WT/$f" 2>/dev/null || echo 0)"
    total=$((total + n))
  done < "$1"
  echo "$total"
}

# run_gates merged-sha old-head resolved(0|1) -> GATE_RESULT (pass|none|fail|infra) and GATE_WHY
run_gates() {
  local merged="$1" old="$2" resolved="$3" tmp manifest raw names src res
  GATE_RESULT=infra; GATE_WHY=""
  [ -f "$GATES" ] || { GATE_WHY="the gate runner $GATES is missing"; return; }
  tmp="$(mktemp -d)"; manifest="$tmp/manifest.json"; raw="$tmp/diff"
  if ! python3 "$GATES" load --main "$MAIN" --base-sha "$BASE_SHA" --repo "$REPO" > "$manifest" 2>"$tmp/err"; then
    GATE_RESULT=fail; GATE_WHY="the gate manifest at $BASE ${BASE_SHA:0:12} is invalid: $(head -c 300 "$tmp/err" | tr '\n' ' ')"
    rm -rf "$tmp"; return
  fi
  # Everything the merged commit differs in from either parent: the PR's own changes and what
  # develop brought in. Duplicates are harmless to select.
  { git -C "$MAIN" diff-tree -r -z --no-renames --raw "$old" "$merged"
    git -C "$MAIN" diff-tree -r -z --no-renames --raw "$BASE_SHA" "$merged"; } > "$raw" \
    && python3 "$GATES" changes --raw "$raw" --changed-out "$raw.changed" --gitlinks-out "$raw.gitlinks" \
    || { GATE_WHY="could not list the merged commit's changes"; rm -rf "$tmp"; return; }
  src="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("source"))' "$manifest" 2>/dev/null)"
  if [ "$src" = none ]; then
    if python3 "$GATES" docs-only --changed "$raw.changed"; then GATE_RESULT=none; GATE_WHY="documentation only"
    elif [ "$resolved" = 1 ] || [ "$REQUIRE_GATES" = 1 ]; then
      GATE_RESULT=fail; GATE_WHY="$REPO has no gate manifest (.agent-pool/gates.toml on $BASE), so the merged code cannot be tested"
    else GATE_RESULT=none; GATE_WHY="no gate manifest on $BASE; pushed untested, the fresh review is the check"; fi
    rm -rf "$tmp"; return
  fi
  names="$(python3 "$GATES" select --manifest "$manifest" --changed "$raw.changed")" \
    || { GATE_WHY="could not select the gates"; rm -rf "$tmp"; return; }
  if [ "$names" = none ]; then GATE_RESULT=none; GATE_WHY="no gate applies to the changed paths"; rm -rf "$tmp"; return; fi
  printf '%s\n' "$names" > "$tmp/select"
  mkdir -p "$POOL_STATE/gate-work" "$POOL_STATE/gate-cache"
  GATE_DIR="$(mktemp -d "$POOL_STATE/gate-work/update-${REPO//\//__}-XXXXXX")" || { GATE_WHY="no gate work dir"; rm -rf "$tmp"; return; }
  # A clean export of the merged commit with no .git, as the pool's gate_checkout does.
  if ! { GIT_INDEX_FILE="$GATE_DIR.index" git -C "$MAIN" read-tree "$merged" \
         && GIT_INDEX_FILE="$GATE_DIR.index" git -C "$MAIN" --work-tree="$GATE_DIR" checkout-index -a -f; }; then
    GATE_WHY="could not check out $merged for the gates"; rm -rf "$tmp"; return
  fi
  rm -f "$GATE_DIR.index"
  log "gates: running $(tr '\n' ' ' < "$tmp/select")at ${merged:0:12} (budget ${GATE_BUDGET}s)"
  python3 "$GATES" run --manifest "$manifest" --gate-dir "$GATE_DIR" --select "$tmp/select" \
    --runs "$tmp" --tag "update" --budget "$GATE_BUDGET" --lock "$POOL_STATE/gates.lock" \
    --cache-root "$POOL_STATE/gate-cache" --repo "$REPO" > "$tmp/run.json" 2>>"$LOG"
  IFS=$'\t' read -r res GATE_WHY < <(python3 -c 'import json,sys
try: d = json.load(open(sys.argv[1]))
except (OSError, ValueError): d = {"result": "infra", "reason": "the gate runner left no result"}
print(d.get("result") or "infra", (d.get("reason") or "-").replace("\t", " ").replace("\n", " "), sep="\t")' "$tmp/run.json")
  [ "$GATE_WHY" = - ] && GATE_WHY=""
  case "$res" in
    pass) GATE_RESULT=pass ;;
    gate-fail|gate-timeout|gate-resource) GATE_RESULT=fail; GATE_WHY="gates $res${GATE_WHY:+: $GATE_WHY}" ;;
    *) GATE_RESULT=infra; GATE_WHY="${GATE_WHY:-the gate run failed}" ;;
  esac
  rm -rf "$tmp"
}

# resolve_conflicts pr headref files-nul -> 0 with the merge committed, else 1 with WHY
resolve_conflicts() {
  local pr="$1" headref="$2" list="$3" nfiles nlines f changed hits manifest
  nfiles="$(tr -cd '\0' < "$list" | wc -c)"
  nlines="$(conflict_lines "$list")"
  if [ "$nfiles" -gt "$MAX_FILES" ] || [ "$nlines" -gt "$MAX_LINES" ]; then
    WHY="the merge of $BASE conflicts in $nfiles file(s), $nlines conflicted line(s) (limit $MAX_FILES files, $MAX_LINES lines): too large to resolve automatically ($(tr '\0' ' ' < "$list" | head -c 400))"
    return 1
  fi
  if [ -z "$RESOLVER" ]; then WHY="the merge of $BASE conflicts ($(tr '\0' ' ' < "$list" | head -c 400)) and no conflict resolver is configured"; return 1; fi
  [ -x "$RESOLVER" ] || { WHY="the conflict resolver $RESOLVER is not executable"; return 1; }
  log "#$pr: $nfiles conflicted file(s), $nlines line(s); handing them to $RESOLVER"
  if ! ( cd "$WT" && PR_UPDATE_PR="$pr" PR_UPDATE_REPO="$REPO" PR_UPDATE_BASE="$BASE" PR_UPDATE_HEADREF="$headref" \
         PR_UPDATE_CONFLICTS="$list" PR_UPDATE_LOG="$LOG" PR_UPDATE_POOL_ROOT="$POOL_ROOT" \
         timeout -k 30 "$RESOLVER_TIMEOUT" "$RESOLVER" ) >>"$LOG" 2>&1; then
    WHY="the AI conflict resolver could not resolve $(tr '\0' ' ' < "$list" | head -c 400)"
    return 1
  fi
  # The resolver may only edit the conflicted files, and must leave no marker in them.
  while IFS= read -r -d '' f; do
    if grep -qE '^(<<<<<<<|>>>>>>>)( |$)|^=======$' "$WT/$f" 2>/dev/null; then
      WHY="the AI conflict resolver left conflict markers in $f"; return 1
    fi
  done < "$list"
  changed="$( (git -C "$WT" diff --name-only -z; git -C "$WT" ls-files -o --exclude-standard -z) | sort -zu \
    | comm -z -23 - <(sort -zu "$list") | tr '\0' ' ')"
  if [ -n "$changed" ]; then WHY="the AI conflict resolver changed files outside the conflict: $changed"; return 1; fi
  # Edits to gate-defining files need a human, as they do for the pool's own resolves.
  manifest="$(mktemp)"
  if python3 "$GATES" load --main "$MAIN" --base-sha "$BASE_SHA" --repo "$REPO" > "$manifest" 2>/dev/null; then
    hits="$(python3 "$GATES" protected --manifest "$manifest" --changed "$list" --gitlinks /dev/null 2>/dev/null)" || hits="?"
    rm -f "$manifest"
    if [ "$hits" != none ]; then WHY="the conflict is in gate-defining files ($(printf '%s' "$hits" | tr '\n' ' ')); a human must resolve it"; return 1; fi
  else
    rm -f "$manifest"
  fi
  xargs -0 git -C "$WT" add -- < "$list" || { WHY="could not stage the resolved files"; return 1; }
  git -C "$WT" commit -q --no-edit >/dev/null 2>&1 || { WHY="could not commit the resolved merge"; return 1; }
  return 0
}

updated=0
for row in "${CANDIDATES[@]}"; do
  IFS=$'\t' read -r pr headref sha held <<<"$row"
  cleanup_pr
  if [ "$held" != - ]; then log "#$pr: busy or waiting on a human ($held); not updating"; continue; fi
  if ! headref_safe "$headref"; then log "#$pr: head branch '$headref' is not one this tick pushes to; skipping"; continue; fi
  if [ "$(git -C "$MAIN" rev-parse --verify -q "refs/remotes/$REMOTE/$headref^{commit}")" != "$sha" ]; then
    log "#$pr: $REMOTE/$headref is not the PR head ${sha:0:12} (a fork, or it moved since the fetch); skipping"; continue
  fi
  if git -C "$MAIN" merge-base --is-ancestor "$BASE_SHA" "$sha"; then continue; fi
  if [ "$DRY_RUN" = 1 ]; then log "DRY: #$pr ($headref at ${sha:0:12}) is behind $BASE ${BASE_SHA:0:12}; would merge, gate, push and request a review"; continue; fi

  WT="$WT_ROOT/update-${pr}-$$"
  git -C "$MAIN" worktree add -q --detach "$WT" "$sha" 2>>"$LOG" || { log "#$pr: could not add a worktree at $sha; skipping"; WT=""; continue; }
  msg="Merge $BASE into $headref

Automated update after a merge to $BASE (pr-update.sh): $BASE is at $BASE_SHA."
  resolved=0
  if ! git -C "$WT" merge --no-ff --no-edit -m "$msg" "$BASE_SHA" >>"$LOG" 2>&1; then
    list="$(mktemp)"
    git -C "$WT" diff --name-only --diff-filter=U -z > "$list"
    if [ ! -s "$list" ]; then
      rm -f "$list"; log "#$pr: git merge failed without a conflict (see $LOG); skipping"; continue
    fi
    WHY=""
    if ! resolve_conflicts "$pr" "$headref" "$list"; then rm -f "$list"; cleanup_pr; needs_human "$pr" "$WHY"; continue; fi
    resolved=1; files="$(tr '\0' ' ' < "$list")"; rm -f "$list"
  fi
  merged="$(git -C "$WT" rev-parse HEAD)"
  run_gates "$merged" "$sha" "$resolved"
  case "$GATE_RESULT" in
    infra) log "#$pr: gates could not run ($GATE_WHY); left as it was, the next tick retries"; continue ;;
    fail)  cleanup_pr; needs_human "$pr" "$GATE_WHY"; continue ;;
  esac
  # Last check before the push: the PR head is still the one we merged into.
  if [ "$(python3 "$ADAPTER" head --repo "$REPO" --pr "$pr" 2>/dev/null)" != "$sha" ]; then
    log "#$pr: the head moved while updating; not pushing, the next tick retries"; continue
  fi
  if ! git -C "$MAIN" push -q "$REMOTE" "$merged:refs/heads/$headref" >>"$LOG" 2>&1; then
    log "#$pr: push of ${merged:0:12} to $headref was refused (see $LOG); left as it was"; continue
  fi
  log "#$pr: merged $BASE ${BASE_SHA:0:12} into $headref -> ${merged:0:12}$([ "$resolved" = 1 ] && printf ' (AI-resolved: %s)' "$files"); gates: $GATE_RESULT${GATE_WHY:+ ($GATE_WHY)}"
  relabel "$pr" "$REQUESTED" "$STALE_RESULT"
  body="Automated update: merged \`$BASE\` (${BASE_SHA:0:12}) into \`$headref\` as ${merged:0:12}."
  [ "$resolved" = 1 ] && body="$body Merge conflicts in $files were resolved by the AI conflict resolver; please check them in review."
  body="$body Gates: $GATE_RESULT${GATE_WHY:+ ($GATE_WHY)}. A fresh review is requested."
  comment "$pr" "$body"
  updated=$((updated + 1))
done
cleanup_pr
log "tick complete ($updated PR(s) updated)"
exit 0
