#!/usr/bin/env bash
# One deterministic Gitea PR merge tick. No model worker is involved.
#
# Phase 1 is deliberately narrow: only allowlisted repositories, an explicit
# review:automerge label, a verified review/resolve marker for the current head,
# mergeable=true, and the configured base branch reach the merge entrypoint.
# TODO: add required-status-context gates before broadening beyond the opt-in phase.

set -uo pipefail

if [ -z "${PR_MERGE_PINNED:-}" ]; then
  PR_MERGE_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  export PR_MERGE_HOME
  pinned="$(mktemp -t pr-merge.XXXXXX.sh)"
  cp "${BASH_SOURCE[0]}" "$pinned"
  export PR_MERGE_PINNED="$pinned"
  bash "$pinned" "$@"
  rc=$?
  rm -f "$pinned"
  exit $rc
fi

COMMON="$PR_MERGE_HOME"
ADAPTER="${PR_MERGE_ADAPTER:-$COMMON/gitea-pr.py}"
MARKER="${PR_MERGE_MARKER:-$COMMON/marker.py}"
REPO="${PR_LOOP_REPO:-ElasticGun/TheNightCrew}"
ALLOWED_REPOS="${PR_MERGE_ALLOW_REPOS:-ElasticGun/TheNightCrew}"
BASE="${PR_MERGE_BASE:-develop}"
STYLE="${PR_MERGE_STYLE:-merge}"
DRY_RUN="${DRY_RUN:-0}"
STATE="${PR_LOOP_STATE:-$HOME/.local/state/gitea-pr-loops}"
LOG="$STATE/pr-loop.log"

mkdir -p "$STATE"
log() { printf '%s [merge] %s\n' "$(date -Is)" "$*" | tee -a "$LOG" >&2; }
die() { log "FATAL: $*"; exit 2; }

repo_allowed=0
IFS=',' read -ra allowlist <<<"$ALLOWED_REPOS"
for allowed in "${allowlist[@]}"; do
  [ "$REPO" = "$allowed" ] && repo_allowed=1
done
[ "$repo_allowed" -eq 1 ] || die "$REPO is not in PR_MERGE_ALLOW_REPOS"
case "$STYLE" in merge|rebase|squash|rebase-merge) ;; *) die "unsupported PR_MERGE_STYLE: $STYLE" ;; esac
[ -f "$ADAPTER" ] || die "missing Gitea adapter: $ADAPTER"
[ -f "$MARKER" ] || die "missing marker reader: $MARKER"

exec 9>"$STATE/merge.lock"
if ! flock -n 9; then log "previous merge tick still running; exiting"; exit 0; fi

if ! LISTING="$(python3 "$ADAPTER" list --repo "$REPO" --state open | python3 -c '
import json, re, sys
# agent:claimed/agent:needs-human block the same way review:in-progress/needs-human do --
# agent-pool-core still owns this PR or has already flagged it for a human.
blocked = {"review:needs-human", "review:in-progress", "review:resolving",
           "review:findings", "review:requested", "review:merging",
           "agent:claimed", "agent:needs-human"}
skip = re.compile(r"docblock-backfill|^chore\(#152\)")
for pr in json.load(sys.stdin):
    labels = set(pr["labels"])
    if "review:automerge" not in labels: continue
    if labels & blocked: continue
    if pr["draft"] or pr["is_bot"]: continue
    if skip.search(pr["title"]) or skip.search(pr["head_ref"]): continue
    # review:resolved/review:clean come from pr-loop.sh; agent:done comes from
    # agent-pool-core. Either producer is accepted. "agent" defers the clean-vs-resolved
    # call to the marker itself (read in bash below), since agent:done carries no such split.
    if "review:resolved" in labels: path = "resolved"
    elif "review:clean" in labels: path = "clean"
    elif "agent:done" in labels: path = "agent"
    else: continue
    print("\t".join([str(pr["number"]), pr["head_sha"], pr["base_ref"], path]))
')"; then
  die "gitea pr list failed; not treating that as an empty queue"
fi
mapfile -t CANDIDATES < <(printf '%s\n' "$LISTING" | sed '/^$/d')
if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  log "no eligible open PR carries review:automerge plus review:clean|review:resolved|agent:done"
  exit 0
fi

labels() { # pr remove add
  python3 "$ADAPTER" label --repo "$REPO" --pr "$1" --remove "$2" --add "$3" >/dev/null
}
comment() { # pr body
  local body_file
  body_file="$(mktemp)"
  printf '%s\n' "$2" > "$body_file"
  python3 "$ADAPTER" comment --repo "$REPO" --pr "$1" --body-file "$body_file" >/dev/null
  rm -f "$body_file"
}
fail_pr() { # pr reason; called only after a real claim
  local pr="$1" reason="$2"
  if ! labels "$pr" "review:merging,review:automerge,review:clean,review:resolved,agent:ready,agent:claimed,agent:done" "review:needs-human"; then
    log "#$pr FAILED: $reason; additionally failed to move claim to review:needs-human"
  else
    comment "$pr" "Automated merge stopped: $reason" || log "warning: failed to comment on #$pr"
    log "#$pr FAILED: $reason"
  fi
  ACTIVE_PR=""
}

ACTIVE_PR=""
cleanup_claim() {
  local rc=$?
  if [ -n "$ACTIVE_PR" ]; then
    fail_pr "$ACTIVE_PR" "merge tick exited unexpectedly while holding the claim (exit $rc)" || true
  fi
}
trap cleanup_claim EXIT HUP INT TERM

for row in "${CANDIDATES[@]}"; do
  IFS=$'\t' read -r pr sha base path <<<"$row"
  if [ "$path" = "agent" ]; then
    # agent:done alone doesn't say clean or resolved -- ask the marker directly. A resolve
    # marker at this head with nothing deferred wins, but only if it answers the latest review
    # (the same r_reviewed = latest-head rule as derive_job in agent-pool/bin/prod-common.sh),
    # so a newer review posted after the resolve is never skipped. Otherwise fall back to a
    # clean review marker at this head. Neither matching means not yet eligible, same as a
    # label mismatch.
    latest_marker="$(PR_LOOP_REPO="$REPO" python3 "$MARKER" latest "$pr" 2>/dev/null || true)"
    read -r l_head l_findings <<<"$latest_marker"
    resolve_marker="$(PR_LOOP_REPO="$REPO" python3 "$MARKER" resolve "$pr" 2>/dev/null || true)"
    read -r r_head r_reviewed _r_fixed r_deferred _r_noted <<<"$resolve_marker"
    if [ -n "$resolve_marker" ] && [ -n "$latest_marker" ] && [ "$r_head" = "$sha" ] \
       && [ "$r_reviewed" = "$l_head" ] && [ "${r_deferred:-1}" = "0" ]; then
      path="resolved"; marker="$resolve_marker"
    else
      if [ -n "$latest_marker" ] && [ "$l_head" = "$sha" ] && [ "${l_findings:-1}" = "0" ]; then
        path="clean"; marker="$latest_marker"
      else
        log "#$pr not yet eligible: agent:done present but no clean/resolved marker at head $sha"
        continue
      fi
    fi
  elif [ "$path" = "resolved" ]; then
    marker="$(PR_LOOP_REPO="$REPO" python3 "$MARKER" resolve "$pr" 2>/dev/null || true)"
  else
    marker="$(PR_LOOP_REPO="$REPO" python3 "$MARKER" latest "$pr" 2>/dev/null || true)"
  fi
  marker_head="${marker%% *}"
  if [ "$DRY_RUN" = "1" ]; then
    if [ "$marker_head" != "$sha" ]; then
      log "DRY: #$pr would fail needs-human: $path marker head ${marker_head:-missing} != current $sha"
    elif [ "$base" != "$BASE" ]; then
      log "DRY: #$pr would fail needs-human: base $base != allowed $BASE"
    else
      log "DRY: #$pr candidate ($path); would claim and merge head $sha into $base with style $STYLE"
    fi
    continue
  fi

  if ! labels "$pr" "review:automerge,review:clean,review:resolved,agent:ready,agent:done" "review:merging"; then
    log "#$pr claim failed; leaving labels unchanged where possible"
    continue
  fi
  ACTIVE_PR="$pr"
  if [ "$marker_head" != "$sha" ]; then
    fail_pr "$pr" "$path marker head ${marker_head:-missing} does not match current head $sha"
    continue
  fi
  if [ "$base" != "$BASE" ]; then
    fail_pr "$pr" "base $base is not allowed; expected $BASE"
    continue
  fi

  merge_out="$(python3 "$ADAPTER" merge --repo "$REPO" --pr "$pr" \
    --expected-head "$sha" --base "$BASE" --style "$STYLE" 2>&1)"
  if [ $? -ne 0 ]; then
    fail_pr "$pr" "$merge_out"
    continue
  fi
  if ! labels "$pr" "review:merging,review:automerge,review:clean,review:resolved,review:requested,review:findings,review:in-progress,review:resolving,review:needs-human,agent:ready,agent:claimed,agent:done" "review:merged"; then
    log "#$pr merged but terminal relabel failed; manual label repair required"
    continue
  fi
  ACTIVE_PR=""
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  comment "$pr" "Automated merge completed: head=$sha style=$STYLE utc=$now" || log "warning: failed to comment on merged #$pr"
  log "#$pr merged head $sha into $BASE with style $STYLE"
done
