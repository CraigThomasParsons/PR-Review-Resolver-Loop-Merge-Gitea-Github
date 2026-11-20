#!/usr/bin/env bash
# pr-update-resolve.sh: the AI conflict resolver pr-update.sh calls on a small merge conflict.
#
# Runs in the worktree pr-update.sh left mid-merge, with the conflicted paths NUL-separated in
# $PR_UPDATE_CONFLICTS. It asks one provider at a time, in PR_UPDATE_PROVIDERS order (the pool's
# roster order; agy is never used, it has no deny list), to edit exactly those files so no conflict
# markers remain, keeping the intent of both sides. Exit 0 once a provider says it is done; the
# caller then checks the markers are gone and nothing else changed, gates the result, and only
# then commits and pushes. Exit 1 when no provider resolved it.
#
# The providers run under the agent pool's own worker policy (agent-pool/scripts/policy.py, job
# "edit": read and edit the worktree, no git writes, no pushes, no Gitea writes), with the same
# pushurl override and empty-key environment as agent-pool/bin/prod-common.sh. A provider that is
# cooling down in the pool (cooldown.py active) is skipped; a limit it hits here is recorded there.
#
# Environment: PR_UPDATE_CONFLICTS, PR_UPDATE_PR, PR_UPDATE_REPO, PR_UPDATE_BASE,
# PR_UPDATE_HEADREF, PR_UPDATE_POOL_ROOT (set by pr-update.sh); PR_UPDATE_PROVIDERS=claude,cursor;
# CLAUDE_BIN, CURSOR_AGENT_BIN, AGENT_POOL_MODEL_CLAUDE (opus), AGENT_POOL_MODEL_CURSOR (auto),
# AGENT_POOL_STATE.
set -uo pipefail

WT="$(pwd)"
LIST="${PR_UPDATE_CONFLICTS:?}"
POOL_ROOT="${PR_UPDATE_POOL_ROOT:?}"
SCRIPTS="$POOL_ROOT/agent-pool/scripts"
ADAPTER="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)/gitea-pr.py"
PROVIDERS="${PR_UPDATE_PROVIDERS:-claude,cursor}"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || true)}"
CURSOR_AGENT_BIN="${CURSOR_AGENT_BIN:-$(command -v cursor-agent || true)}"
export AGENT_POOL_STATE="${AGENT_POOL_STATE:-$HOME/.local/state/agent-pool}"
RUNS="$(mktemp -d)"; trap 'rm -rf "$RUNS"; rm -rf "$WT/.cursor/cli.json"' EXIT
REPORT="$RUNS/report.md"
log() { printf '%s [update-resolve] [%s#%s] %s\n' "$(date -Is)" "${PR_UPDATE_REPO:-?}" "${PR_UPDATE_PR:-?}" "$*" >&2; }

files="$(tr '\0' '\n' < "$LIST" | sed 's/^/- /')"
PROMPT="$RUNS/prompt.txt"
cat > "$PROMPT" <<P
You are resolving a git merge conflict in the working directory $WT.

The branch \`${PR_UPDATE_HEADREF:-?}\` (pull request #${PR_UPDATE_PR:-?} in ${PR_UPDATE_REPO:-?}) is having
\`${PR_UPDATE_BASE:-develop}\` merged into it. Git stopped on conflicts in exactly these files:

$files

For each of those files, and only those files:
1. Read the whole file and the conflict regions (<<<<<<< ours = the PR branch, >>>>>>> theirs = ${PR_UPDATE_BASE:-develop}).
2. Edit it so that every conflict marker line is gone and the result keeps the intent of BOTH sides.
   Use git log / git show / git diff (read-only) to understand each side if you need to.
3. Do not edit, create or delete any other file. Do not run git add, commit, merge, push or any
   other command that writes git history; the controller commits and tests your result.

If a conflict cannot be resolved safely (the two sides contradict each other), leave that file
with its markers in place; the controller will hand it to a human.
When you are finished, write one line to $REPORT: RESOLVED or CANNOT_RESOLVE.
P

cooling() { # provider
  python3 "$SCRIPTS/cooldown.py" active --provider "$1" >/dev/null 2>&1
}

for p in ${PROVIDERS//,/ }; do
  case "$p" in
    claude) [ -x "$CLAUDE_BIN" ] || { log "claude is not installed; skipping"; continue; } ;;
    cursor) [ -x "$CURSOR_AGENT_BIN" ] || { log "cursor-agent is not installed; skipping"; continue; } ;;
    *) log "provider $p cannot resolve conflicts here (only claude and cursor); skipping"; continue ;;
  esac
  if cooling "$p"; then log "$p is cooling down in the pool; skipping"; continue; fi
  rm -f "$REPORT"
  ALLOW=(); DENY=(); CMD=(); CMD_ENV=(); STDIN=/dev/null
  case "$p" in
    claude)
      while IFS=$'\t' read -r kind rule; do
        case "$kind" in allow) ALLOW+=("$rule") ;; deny) DENY+=("$rule") ;; esac
      done < <(python3 "$SCRIPTS/policy.py" rules --provider claude --job edit --adapter "$ADAPTER" --worktree "$WT" --report "$REPORT")
      [ "${#ALLOW[@]}" -gt 0 ] || { log "policy.py gave claude no rules; skipping"; continue; }
      CMD_ENV=(-u ANTHROPIC_API_KEY)
      CMD=("$CLAUDE_BIN" -p --output-format json --model "${AGENT_POOL_MODEL_CLAUDE:-opus}"
        --permission-mode default --add-dir "$RUNS"
        --settings "$(python3 "$SCRIPTS/policy.py" hook-settings --provider claude --job edit --adapter "$ADAPTER" --worktree "$WT" --report "$REPORT")"
        --allowedTools "${ALLOW[@]}" --disallowedTools "${DENY[@]}")
      STDIN="$PROMPT" ;;
    cursor)
      mkdir -p "$WT/.cursor"
      python3 "$SCRIPTS/policy.py" cursor-json --provider cursor --job edit --adapter "$ADAPTER" --worktree "$WT" --report "$REPORT" \
        > "$WT/.cursor/cli.json" || { log "policy.py gave cursor no rules; skipping"; continue; }
      CMD=("$CURSOR_AGENT_BIN" -p --trust --workspace "$WT" --output-format stream-json
        --model "${AGENT_POOL_MODEL_CURSOR:-auto}" "$(cat "$PROMPT")") ;;
  esac
  log "asking $p to resolve $(tr '\0' ' ' < "$LIST")"
  env "${CMD_ENV[@]}" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.pushurl \
    GIT_CONFIG_VALUE_0=/nonexistent/pr-update-resolvers-never-push "${CMD[@]}" \
    <"$STDIN" >"$RUNS/out-$p" 2>"$RUNS/err-$p"
  rc=$?
  rm -rf "$WT/.cursor/cli.json"; rmdir "$WT/.cursor" 2>/dev/null
  cls="$(python3 "$SCRIPTS/classify.py" --provider "$p" --exit "$rc" --stdout "$RUNS/out-$p" --stderr "$RUNS/err-$p" 2>/dev/null)"
  verdict="${cls%%$'\t'*}"
  case "$verdict" in
    limit) python3 "$SCRIPTS/cooldown.py" record --provider "$p" --reason "pr-update conflict resolve: $(printf '%s' "$cls" | cut -f2)" >/dev/null 2>&1
           log "$p hit a limit; trying the next provider"; continue ;;
    setup) log "$p setup fault: $(printf '%s' "$cls" | cut -f2); trying the next provider"; continue ;;
  esac
  if grep -qx 'RESOLVED' "$REPORT" 2>/dev/null; then log "$p reports the conflicts resolved"; exit 0; fi
  log "$p did not resolve the conflicts (exit $rc, $verdict, report: $(head -c 80 "$REPORT" 2>/dev/null || echo none))"
  # A provider that said it could not resolve is an answer, not an outage: stop there.
  grep -qx 'CANNOT_RESOLVE' "$REPORT" 2>/dev/null && exit 1
done
exit 1
