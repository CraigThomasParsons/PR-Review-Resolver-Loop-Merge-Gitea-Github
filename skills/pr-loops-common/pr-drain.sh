#!/usr/bin/env bash
# pr-drain — consume the queue pr-trigger fills, one PR at a time, until it is empty.
#
# Installed as ~/.local/bin/pr-drain and run by pr-trigger-drain.service whenever
# pr-trigger-drain.path sees a file in the queue. Not meant to be run by hand, though doing so is
# harmless: it takes the same drain lock the service does.
#
# For each queued PR:
#   1. allowlist   PR_PIPELINE_REPOS, else `php artisan nightcrew:list-pr-repos` (as pr-pipeline.sh)
#   2. checkout    ~/.config/pulse/night_crew_repositories.json, else ~/Code/<name> (as pr-pipeline.sh)
#   3. pre-check   one adapter `list` call: drop closed and draft PRs, and drop label events
#                  (with no label stage pending) when the PR no longer carries review:requested
#                  or review:findings, so the loop's own relabel events cost one API call
#   4. label stage only for opened/reopened/synchronize: `nightcrew:label-prs --repo R --pr N`
#                  when TheNightCrew supports those options, otherwise the full sweep
#   5. pr-loop.sh review, then resolve, with PR_LOOP_PR=N and PR_LOOP_LOCK_WAIT, sharing
#                  review.lock / resolve.lock, the head marker and the label claim with the
#                  hourly timer. Merge is never run here; it stays the merge tick's job.
# Every item is consumed, success or not, so the path unit cannot spin. There is no retry: if
# pr-loop.sh skips (busy box, low memory, lock wait exhausted), the hourly timer is the backstop.
#
# Environment (all optional):
#   PR_LOOP_STATE         state directory (default ~/.local/state/gitea-pr-loops)
#   PR_LOOPS_COMMON       the deployed engine (default ~/.claude/skills/pr-loops-common)
#   NIGHT_CREW_DIR        TheNightCrew checkout for artisan (default ~/Code/TheNightCrew)
#   PR_PIPELINE_REPOS     comma-separated allowlist; default asks TheNightCrew
#   PR_TRIGGER_LOCK_WAIT  seconds pr-loop.sh may wait for its lock (default 3600)
#   PR_LOOP_ENGINE        pr-loop (the only engine until the agent pool lands)
#   DRY_RUN=1             passed through to label-prs and pr-loop.sh
#
# Exit codes: 0 normal (including "nothing to do"), 2 setup fault (queued items are dropped).

set -uo pipefail

STATE="${PR_LOOP_STATE:-$HOME/.local/state/gitea-pr-loops}"
COMMON="${PR_LOOPS_COMMON:-$HOME/.claude/skills/pr-loops-common}"
CREW="${NIGHT_CREW_DIR:-$HOME/Code/TheNightCrew}"
LOCK_WAIT="${PR_TRIGGER_LOCK_WAIT:-3600}"
ENGINE="${PR_LOOP_ENGINE:-pr-loop}"
DRY="${DRY_RUN:-0}"
ADAPTER="$COMMON/gitea-pr.py"
QUEUE="$STATE/queue"
PROCESSING="$STATE/processing"

log() { printf '%s pr-drain %s\n' "$(date -Is)" "$*" >&2; }

mkdir -p "$QUEUE" "$PROCESSING" || { log "FATAL: cannot create $QUEUE / $PROCESSING"; exit 2; }

drop_all() { # reason
  local f
  for f in "$QUEUE"/*.json "$PROCESSING"/*.json; do
    [ -e "$f" ] || continue
    log "dropping $(basename "$f"): $1"; rm -f "$f"
  done
}

fault=""
[ "$ENGINE" = pr-loop ] || fault="unsupported PR_LOOP_ENGINE '$ENGINE'"
[[ "$LOCK_WAIT" =~ ^[0-9]+$ ]] || fault="PR_TRIGGER_LOCK_WAIT must be whole seconds (got '$LOCK_WAIT')"
[ -x "$COMMON/pr-loop.sh" ] || fault="missing or not executable: $COMMON/pr-loop.sh"
[ -f "$ADAPTER" ] || fault="missing Gitea adapter: $ADAPTER"
if [ -n "$fault" ]; then log "FATAL: $fault"; drop_all "setup fault"; exit 2; fi

checkout_for() { # repo -> prints the local clone, or fails
  local repo="$1" dir
  dir="$(python3 - "$repo" <<'PY' 2>/dev/null
import json, os, sys
path = os.path.expanduser("~/.config/pulse/night_crew_repositories.json")
try:
    registry = json.load(open(path))
except Exception:
    registry = {}
entry = registry.get(sys.argv[1]) or {}
print(entry.get("project_dir", ""))
PY
)"
  [ -n "$dir" ] || dir="$HOME/Code/${repo##*/}"
  [ -d "$dir/.git" ] || [ -f "$dir/.git" ] || return 1
  echo "$dir"
}

ALLOW=""
allowlist() { # resolved once per run
  if [ -z "$ALLOW" ]; then
    ALLOW="${PR_PIPELINE_REPOS:-}"
    if [ -z "$ALLOW" ]; then
      ALLOW="$(cd "$CREW" 2>/dev/null && php artisan nightcrew:list-pr-repos 2>/dev/null | tr -d '\r' | paste -sd, -)"
    fi
  fi
  printf '%s\n' "$ALLOW"
}

SCOPED=""
label_prs_scoped() { # does this NightCrew's label-prs take --repo and --pr? resolved once per run
  if [ -z "$SCOPED" ]; then
    local help; help="$(cd "$CREW" 2>/dev/null && php artisan help nightcrew:label-prs 2>/dev/null)"
    if grep -q -- '--repo' <<<"$help" && grep -q -- '--pr' <<<"$help"; then SCOPED=yes; else SCOPED=no; fi
  fi
  [ "$SCOPED" = yes ]
}

label_stage() { # repo pr
  local args=(nightcrew:label-prs)
  if label_prs_scoped; then args+=(--repo "$1" --pr "$2"); fi
  [ "$DRY" = 1 ] && args+=(--dry-run)
  if [ ! -d "$CREW" ]; then log "  label stage skipped: no TheNightCrew checkout at $CREW"; return 0; fi
  log "  label stage: php artisan ${args[*]}"
  ( cd "$CREW" && php artisan "${args[@]}" ) 8>&- 2>&1 | sed 's/^/    /' >&2 || log "  warning: label stage failed; continuing"
}

process() { # path of a file in $PROCESSING
  local f="$1" fields repo pr sha event label label_stage_flag main live allow
  if ! fields="$(python3 - "$f" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
print("\x1f".join([str(d["repo"]), str(d["pr"]), str(d.get("sha", "")), str(d.get("event", "")),
                    str(d.get("label", "")), "true" if d.get("label_stage") else "false"]))
PY
)"; then
    log "$(basename "$f"): unreadable queue file; dropped"; return
  fi
  # Not tab-separated: tab is IFS whitespace, so an empty label would collapse and shift the rest.
  IFS=$'\x1f' read -r repo pr sha event label label_stage_flag <<<"$fields"
  if ! [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || ! [[ "$pr" =~ ^[1-9][0-9]*$ ]]; then
    log "$(basename "$f"): bad repo/pr in queue file; dropped"; return
  fi
  log "$repo#$pr: event=$event${label:+ label=$label} sha=$sha"

  allow="$(allowlist)"
  if [ -z "$allow" ]; then log "$repo#$pr: no allowlist resolved (set PR_PIPELINE_REPOS); dropped"; return; fi
  case ",$allow," in *",$repo,"*) ;; *) log "$repo#$pr: not in the PR pipeline allowlist; dropped"; return ;; esac

  if ! main="$(checkout_for "$repo")"; then log "$repo#$pr: no local checkout; dropped"; return; fi

  if ! live="$(python3 "$ADAPTER" list --repo "$repo" --state open | PR="$pr" python3 -c '
import json, os, sys
want = int(os.environ["PR"])
for p in json.load(sys.stdin):
    if p["number"] == want:
        print("draft" if p["draft"] else "open", " ".join(p["labels"]))
        break
else:
    print("absent")
')"; then
    log "$repo#$pr: could not read the PR from Gitea; dropped (the hourly tick will catch up)"; return
  fi
  local pstate="${live%% *}" plabels=" ${live#* } "
  case "$pstate" in
    absent) log "$repo#$pr: not open; dropped"; return ;;
    draft) log "$repo#$pr: draft; dropped"; return ;;
  esac
  if [ "$event" = labeled ] && [ "$label_stage_flag" != true ] \
     && [[ "$plabels" != *" review:requested "* ]] && [[ "$plabels" != *" review:findings "* ]]; then
    log "$repo#$pr: label event but the PR carries neither review:requested nor review:findings now; dropped"
    return
  fi

  [ "$label_stage_flag" = true ] && label_stage "$repo" "$pr"

  local mode
  for mode in review resolve; do
    log "$repo#$pr: pr-loop.sh $mode"
    DRY_RUN="$DRY" PR_LOOP_REPO="$repo" PR_LOOP_MAIN="$main" PR_LOOP_PR="$pr" PR_LOOP_LOCK_WAIT="$LOCK_WAIT" \
      "$COMMON/pr-loop.sh" "$mode" 8>&- 2>&1 | sed "s|^|    [$repo#$pr] |" >&2
  done
}

recover() { # leftovers from a killed run go back to the queue unless a newer event superseded them
  local f base
  for f in "$PROCESSING"/*.json; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    if [ -e "$QUEUE/$base" ]; then
      log "$base: leftover from an interrupted run, superseded by a newer event"; rm -f "$f"
    else
      log "$base: leftover from an interrupted run; requeued"; mv -f "$f" "$QUEUE/$base"
    fi
  done
}

next_item() { # oldest queued file
  find "$QUEUE" -maxdepth 1 -type f -name '*.json' -printf '%T@ %p\n' 2>/dev/null | sort -n | head -1 | cut -d' ' -f2-
}

exec 8>"$STATE/drain.lock"
while :; do
  if ! flock -n 8; then log "another drain holds the lock and will see the queue; exiting"; exit 0; fi
  recover
  while item="$(next_item)"; [ -n "$item" ]; do
    base="$(basename "$item")"
    mv -f "$item" "$PROCESSING/$base" 2>/dev/null || continue
    process "$PROCESSING/$base"
    rm -f "$PROCESSING/$base"
  done
  flock -u 8
  # A trigger that landed between the last scan and the unlock would otherwise wait for the next
  # path-unit activation.
  [ -n "$(next_item)" ] || break
done
exit 0
