#!/usr/bin/env bash
# pr-trigger --repo OWNER/NAME --pr N --sha HEAD [--event E] [--label L]
#
# The event-driven entry point to the PR loop, installed as ~/.local/bin/pr-trigger. The Gitea
# Actions template (TheGiteaCodeFactory, templates/pr-review-trigger.yml, runs-on: factory-host)
# calls it on pull_request_target; a person can call it by hand with --event manual.
#
# It does no review itself and needs no network, token or model: it validates its arguments,
# decides whether the event matters, and drops one small JSON file into a queue that
# pr-trigger-drain.path watches. pr-drain then runs label -> review -> resolve for that PR under the
# same locks, markers and label claims as the hourly timer, so a double trigger (event plus timer,
# or a burst of events) costs at most a skipped tick. See docs/EVENT-TRIGGER.md.
#
# Events (Gitea spells some of them differently from GitHub; both are accepted):
#   opened, reopened, synchronize|synchronized   queued; the drainer also runs the label stage
#   labeled|label_updated                        queued only for review:requested or
#                                                review:findings, or an empty --label (Gitea may
#                                                leave label.name empty; the drainer re-checks)
#   manual, or no --event                        queued
#   anything else                                ignored
#
# One queue file per PR (<owner>__<name>__<pr>.json): a newer event overwrites an older one that
# has not been picked up yet, keeping the newest SHA. A pending label stage is never dropped by
# the overwrite.
#
# Exit codes: 0 queued or ignored (one-line reason on stdout), 2 bad arguments,
#             3 misconfiguration or write failure.
#
# Environment: PR_LOOP_STATE  state directory (default ~/.local/state/gitea-pr-loops); the queue
#              is $PR_LOOP_STATE/queue and every call is logged to $PR_LOOP_STATE/trigger.log.

set -uo pipefail

STATE="${PR_LOOP_STATE:-}"
if [ -z "$STATE" ] && [ -n "${HOME:-}" ]; then STATE="$HOME/.local/state/gitea-pr-loops"; fi

RAW="$*"
tlog() { # one line to trigger.log; best effort, never fatal
  [ -n "$STATE" ] || return 0
  mkdir -p "$STATE" 2>/dev/null || return 0
  printf '%s pr-trigger %s\n' "$(date -Is)" "$*" 2>/dev/null >> "$STATE/trigger.log" 2>/dev/null || true
}
bad() { echo "pr-trigger: $*" >&2; tlog "rejected (exit 2): $* -- args: $(printf '%q' "$RAW")"; exit 2; }
broken() { echo "pr-trigger: $*" >&2; tlog "failed (exit 3): $*"; exit 3; }
usage() { echo "usage: pr-trigger --repo OWNER/NAME --pr N --sha HEAD [--event E] [--label L]" >&2; }

repo="" pr="" sha="" event="" label=""
have_repo=0 have_pr=0 have_sha=0
while (($#)); do
  case "$1" in
    --repo|--pr|--sha|--event|--label)
      [ $# -ge 2 ] || { usage; bad "$1 needs a value"; }
      case "$1" in
        --repo) repo="$2"; have_repo=1 ;;
        --pr) pr="$2"; have_pr=1 ;;
        --sha) sha="$2"; have_sha=1 ;;
        --event) event="$2" ;;
        --label) label="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; bad "unknown argument: $1" ;;
  esac
done

[ "$have_repo" = 1 ] && [ "$have_pr" = 1 ] && [ "$have_sha" = 1 ] || { usage; bad "--repo, --pr and --sha are required"; }
[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || bad "bad --repo '$repo' (want OWNER/NAME)"
owner="${repo%%/*}" name="${repo#*/}"
case "$owner" in .|..) bad "bad --repo '$repo'" ;; esac
case "$name" in .|..) bad "bad --repo '$repo'" ;; esac
[[ "$pr" =~ ^[1-9][0-9]*$ ]] || bad "bad --pr '$pr' (want a PR number)"
sha="${sha,,}"
[[ "$sha" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || bad "bad --sha '$sha' (want a 40 or 64 hex digit commit id)"

label_stage=false
case "$event" in
  opened|reopened) kind="$event"; label_stage=true ;;
  synchronize|synchronized) kind=synchronize; label_stage=true ;;
  labeled|label_updated) kind=labeled ;;
  manual|"") kind=manual ;;
  *) echo "ignored: event $event"; tlog "ignored: event $(printf '%q' "$event") for $repo#$pr"; exit 0 ;;
esac
if [ "$kind" = labeled ]; then
  case "$label" in
    review:requested|review:findings|"") ;;
    *) echo "ignored: label $label"; tlog "ignored: label $(printf '%q' "$label") for $repo#$pr"; exit 0 ;;
  esac
else
  label=""
fi

[ -n "$STATE" ] || broken "neither PR_LOOP_STATE nor HOME is set"
mkdir -p "$STATE/queue" "$STATE/queue.tmp" 2>/dev/null || broken "cannot create $STATE/queue"
[ -w "$STATE/queue" ] && [ -w "$STATE/queue.tmp" ] || broken "$STATE/queue is not writable"

file="${owner}__${name}__${pr}.json"
dest="$STATE/queue/$file"

# Serialise the read-modify-write with any concurrent pr-trigger for the same queue.
exec 7>"$STATE/queue.tmp/.lock" || broken "cannot open $STATE/queue.tmp/.lock"
flock -w 10 7 || broken "timed out waiting for the queue lock"

# Coalescing keeps the newest event, but an opened/reopened/synchronize still waiting in the
# queue must keep its label stage when a labeled event lands on top of it.
if [ "$label_stage" = false ] && [ -f "$dest" ] && grep -q '"label_stage": true' "$dest" 2>/dev/null; then
  label_stage=true
fi

tmp="$(mktemp "$STATE/queue.tmp/$file.XXXXXX" 2>/dev/null)" || broken "cannot write in $STATE/queue.tmp"
received="$(date -Is)"
# Every interpolated value is validated above or drawn from a fixed set, so none needs escaping.
if ! printf '{"repo": "%s", "pr": %s, "sha": "%s", "event": "%s", "raw_event": "%s", "label": "%s", "label_stage": %s, "received_at": "%s"}\n' \
     "$repo" "$pr" "$sha" "$kind" "$event" "$label" "$label_stage" "$received" > "$tmp" \
   || ! sync "$tmp" 2>/dev/null \
   || ! mv -f "$tmp" "$dest" 2>/dev/null; then
  rm -f "$tmp"
  broken "could not write $dest"
fi

shown_label="${label:-}"
[ "$kind" = labeled ] && [ -z "$label" ] && shown_label=unknown
echo "queued: $repo#$pr $sha event=$kind${shown_label:+ label=$shown_label}"
tlog "queued: $repo#$pr sha=$sha event=$(printf '%q' "$event") kind=$kind label=${shown_label:-none} label_stage=$label_stage"
exit 0
