#!/usr/bin/env bash
# Which agent am I, and which agents can I hand work to?
#
# Two jobs, one place:
#   (no args)  identify the CURRENT runtime      -> {"agent":...}
#   --probe    inventory AVAILABLE vendor CLIs   -> {"available":[...]}
#
# Used by the slice/pr skills to adapt behaviour, and by the crew coach to route.
#
# Marker confidence is recorded honestly. "high" = verified on this box.
# "medium" = inferred from vendor-shipped code, not yet confirmed from inside
# that runtime. Run this script INSIDE a vendor's session and pass --learn to
# promote its marker to verified (appends to the overrides file below).

set -uo pipefail
OVERRIDES="${AGENT_DETECT_OVERRIDES:-$HOME/.config/crew/agent-markers.env}"
[ -f "$OVERRIDES" ] && . "$OVERRIDES"

detect_agent() {
  # 1. Claude Code — VERIFIED: CLAUDECODE=1 is set in every session.
  if [ -n "${CLAUDECODE:-}" ]; then echo "claude high CLAUDECODE"; return; fi
  # 2. Cursor CLI — inferred from cursor's own skills (CURSOR_AGENT_STORE_FILES_DIR).
  if [ -n "${CURSOR_AGENT:-}${CURSOR_AGENT_STORE_FILES_DIR:-}${CURSOR_TRACE_ID:-}" ]; then
    echo "cursor medium CURSOR_AGENT*"; return; fi
  # 3. Codex — CODEX_SANDBOX is set inside codex's sandboxed shell. Deliberately
  #    NOT matching CODEX_COMPANION_*: those are set by the Claude plugin, so
  #    they mean "Claude talking to Codex", not "running as Codex".
  if [ -n "${CODEX_SANDBOX:-}" ]; then echo "codex medium CODEX_SANDBOX"; return; fi
  if [ -n "${CODEX_HOME:-}" ] && [ -z "${CODEX_COMPANION_SESSION_ID:-}" ]; then
    echo "codex low CODEX_HOME"; return; fi
  # 4/5. Grok and Gemini headless runs inherit the caller's env and set no marker
  #      of their own; they are addressed as workers, they do not host skills.
  echo "unknown low none"
}

probe_available() {
  # Availability for routing. Presence on PATH only. Liveness/quota is a
  # separate, costlier question -- see the note in the coach notes doc.
  local first=1
  printf '{"available":['
  for entry in "claude:claude" "codex:codex" "cursor:cursor-agent" "grok:$HOME/.grok/bin/grok" "gemini:gemini"; do
    local name="${entry%%:*}" cmd="${entry#*:}" path
    path="$(command -v "$cmd" 2>/dev/null || { [ -x "$cmd" ] && echo "$cmd"; })"
    [ -n "$path" ] || continue
    [ $first -eq 1 ] || printf ','
    printf '{"agent":"%s","path":"%s"}' "$name" "$path"
    first=0
  done
  printf ']}\n'
}

case "${1:-}" in
  --probe) probe_available ;;
  --learn)
    read -r a c s <<<"$(detect_agent)"
    mkdir -p "$(dirname "$OVERRIDES")"
    echo "# learned $(date -Is): agent=$a via=$s" >> "$OVERRIDES"
    echo "learned: agent=$a confidence=$c signal=$s -> $OVERRIDES" ;;
  *)
    read -r a c s <<<"$(detect_agent)"
    printf '{"agent":"%s","confidence":"%s","signal":"%s"}\n' "$a" "$c" "$s" ;;
esac
