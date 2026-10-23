#!/usr/bin/env bash
# classify-pane.sh: capture a tmux worker pane and classify its state for one pipeline tick.
#
# Usage: classify-pane.sh <target> <sentinel> [lines] [state-file]
#   <target>     tmux session/pane, e.g. 0 or mysess:0.1
#   <sentinel>   the current phase's completion sentinel, e.g. PHASE_TDD_DONE
#   [lines]      how many scrollback lines to inspect (default 40)
#   [state-file] writable path persisting the idle streak between stateless ticks;
#                with it, the second consecutive idle tick reports STALLED directly
#
# Eval seam: CLASSIFY_INPUT_FILE=<capture.txt> bypasses tmux and classifies that
# file's content instead. Use it to check a change against a saved pane capture.
#
# This is the PR loops' own copy. It is not the tmux-pipeline skill's classifier, which takes two
# arguments and has no PARKED or STALLED state; pr-loop.sh depends on both.
#
# Prints one of:
#   STATE=WORKING  worker is actively running (or busy in a shell/subagent wait)
#   STATE=BLOCKED  a tool-approval prompt or other selection menu is waiting
#   STATE=RATE_LIMITED  the provider hit a usage or rate limit: HTTP 429, "hit your weekly
#                  limit", "usage limit", or the "Stop and wait / Wait here" menu, on a pane
#                  with no live "esc to interrupt"; or any of those after the worker exited.
#                  The orchestrator kills the worker and falls back; it never answers the menu.
#   STATE=EXITED   the worker process ended (pr-loop.sh's launch script prints
#                  PR_LOOP_WORKER_EXIT=<rc> when it does) with no limit wording on screen
#   STATE=PARKED   a Claude Code PRODUCT dialog needs a human (usage limit, login,
#                  auto-mode setup, credits). NEVER approvable; the orchestrator
#                  must not keep ticking against it.
#   STATE=DONE     sentinel present as a standalone line AND worker idle
#   STATE=IDLE     worker idle, no sentinel (first idle tick, or no state-file)
#   STATE=STALLED  second consecutive idle tick (state-file mode only)
# followed by the captured tail for context.
set -euo pipefail

target="${1:?tmux target, e.g. 0}"
sentinel="${2:?phase sentinel, e.g. PHASE_TDD_DONE}"
lines="${3:-40}"
state_file="${4:-}"

if [ -n "${CLASSIFY_INPUT_FILE:-}" ]; then
  out="$(cat "$CLASSIFY_INPUT_FILE")"
else
  out="$(tmux capture-pane -t "$target" -p -S "-${lines}")"
fi
tail="$(printf '%s\n' "$out" | tail -20)"

# Idle when the "esc to interrupt" affordance is absent from the live footer.
# A backgrounded shell or a subagent wait also means the worker is busy: both
# drop "esc to interrupt" while work continues, so treating them as idle
# produces a spurious nudge into a worker that is waiting correctly.
idle=1
printf '%s\n' "$tail" | grep -qE "esc to interrupt|[0-9]+ shells? still running|↓ to manage|Waiting for [0-9]+ background agents?|background agents to finish|/tasks to see subagents|[◯●][[:space:]]+(general-purpose|main)" && idle=0

# PRODUCT dialogs: things only a human keypress or account action can clear.
# These are categorically NOT tool-approval prompts. Checked against the full
# capture, not just the tail: the dialog text scrolls up as ticks pass while
# the pane stays frozen (the 2026-08-24 incident held one for 821 ticks).
parked=0
printf '%s\n' "$out" | grep -qiE \
  "You've reached your .* limit|/usage-credits|Set up auto mode for your environment|Select login method|log in to continue|purchase more credits|upgrade your plan to continue" && parked=1

# Usage and rate limits. Read from the tail only while the worker is not mid-turn: a reviewer
# whose tool output quotes "429" or "usage limit" from the code under review is still working.
# Once the worker process has exited, the whole capture is the provider's last word. The
# product's own limit dialogs are read from the whole capture like PARKED's, since they scroll.
PRODUCT_LIMIT_RE="[Hh]it your [^.]*limit|You've reached your [^.]*limit|Stop and wait|Wait here|/usage-credits|purchase more credits|upgrade your plan to continue"
LIMIT_RE="API Error[: (]*429|\\b429\\b.*([Rr]ate|[Ll]imit|Too Many)|Too Many Requests|rate_limit_error|[Uu]sage limit|$PRODUCT_LIMIT_RE"
live=0
printf '%s\n' "$tail" | grep -q "esc to interrupt" && live=1
exited=0
printf '%s\n' "$out" | grep -qE '^PR_LOOP_WORKER_EXIT=[0-9]+$' && exited=1
limited=0
if [ "$exited" -eq 1 ]; then
  printf '%s\n' "$out" | grep -qE "$LIMIT_RE" && limited=1
elif [ "$live" -eq 0 ]; then
  printf '%s\n' "$tail" | grep -qE "$LIMIT_RE" && limited=1
  printf '%s\n' "$out" | grep -qE "$PRODUCT_LIMIT_RE" && limited=1
fi

# Sentinel must be its OWN standalone line (optionally a leading bullet), never
# merely embedded in the instruction text echoed back into the pane.
hit=0
printf '%s\n' "$out" | grep -qE "^[[:space:]]*(.[[:space:]]*)?${sentinel}[[:space:]]*$" && hit=1

# Tool-approval prompt patterns, plus any other selection menu: the loop never answers one, so a
# menu it does not recognise must reach BLOCKED (and the strike count) rather than sit as IDLE.
blocked=0
printf '%s\n' "$tail" | grep -qiE "Do you want to (proceed|create|make|run|allow)|^[[:space:]]*1\. Yes|Enter to confirm" && blocked=1

# Idle-streak persistence (state-file mode). Any non-idle tick resets the streak.
streak=0
if [ -n "$state_file" ]; then
  [ -f "$state_file" ] && streak="$(cat "$state_file" 2>/dev/null || echo 0)"
  case "$streak" in ''|*[!0-9]*) streak=0 ;; esac
fi

emit() { echo "STATE=$1"; }

# Sentinel + no live "esc to interrupt" means done. Claude Code 2.1+ keeps
# chrome like "↓ to manage" in the footer forever, which would otherwise keep
# idle=0 and strand a finished worker until WORKER_TIMEOUT.
if [ "$hit" -eq 1 ] && ! printf '%s\n' "$tail" | grep -q "esc to interrupt"; then
  emit DONE
  [ -n "$state_file" ] && echo 0 > "$state_file"
elif [ "$limited" -eq 1 ]; then
  # Before PARKED and BLOCKED: the limit menu is a product dialog and a selection menu too.
  emit RATE_LIMITED
  [ -n "$state_file" ] && echo 0 > "$state_file"
elif [ "$exited" -eq 1 ]; then
  emit EXITED
  [ -n "$state_file" ] && echo 0 > "$state_file"
elif [ "$parked" -eq 1 ] && [ "$idle" -eq 1 ]; then
  # A frozen pane wearing a product dialog. Parked wins over blocked: the
  # dialog is the reason nothing is progressing.
  emit PARKED
  [ -n "$state_file" ] && echo 0 > "$state_file"
elif [ "$blocked" -eq 1 ]; then
  emit BLOCKED
  [ -n "$state_file" ] && echo 0 > "$state_file"
elif [ "$idle" -eq 1 ]; then
  if [ -n "$state_file" ] && [ "$streak" -ge 1 ]; then
    emit STALLED
    echo 0 > "$state_file"
  else
    emit IDLE
    [ -n "$state_file" ] && echo $((streak + 1)) > "$state_file"
  fi
else
  emit WORKING
  [ -n "$state_file" ] && echo 0 > "$state_file"
fi

echo "----TAIL----"
printf '%s\n' "$tail"
