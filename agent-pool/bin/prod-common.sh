#!/usr/bin/env bash
# prod-common.sh MODE
#
# One tick of the provider-parameterized PR worker pool for one Gitea repo. MODE is "review" or
# "resolve", with the same label handoffs as skills/pr-loops-common/pr-loop.sh:
#
#   review  : review:requested -> review:in-progress -> review:findings | review:clean
#   resolve : review:findings  -> review:resolving   -> review:resolved
#   either  : a real verification failure -> review:needs-human (with a comment)
#
# What is different from pr-loop.sh:
#
#   * Workers are headless CLI runs, not tmux panes, and the CLI is chosen per job from
#     PROVIDER_ORDER (claude, cursor, grok, agy, codex). Unset, the order is claude alone.
#   * Each PR job is held by a lease (scripts/lease.py) with a TTL, a heartbeat that renews it,
#     and a fence token that goes up on every claim. Every label and comment write runs through
#     `lease.py guard`, which checks under the job lock that this worker still holds the current
#     fence and refuses the write if not. A worker that lost its lease touches nothing.
#   * A claim label (or "status: in-progress") with no live lease is not a human hold: a dead
#     run's hold expires with its lease and the PR is reclaimed.
#   * A provider limit is not a needs-human. The provider gets a cooldown file (exponential
#     backoff, scripts/cooldown.py), the next provider in the order gets the job, and if none is
#     left the PR goes back to its trigger label. Setup faults (a permission the pool's own
#     configuration denied, a missing binary or model) get no cooldown and are reported loudly:
#     a SETUP FAULT log line, faults/<provider>.json, and exit 2 at the end of the tick.
#
# Limits are recognised by scripts/classify.py's signatures (claude's PARKED product dialogs
# and "Credit balance is too low"; 429, rate limit, quota exceeded, insufficient credits for
# every provider) and by one behavioural signature: a run that ends inside
# AGENT_POOL_FAST_FAIL_SECS without leaving its marker comment. That is the 32-second credit wall
# that mislabelled a dozen PRs needs-human.
#
# Permissions are per worktree and per invocation only: claude --allowedTools/--disallowedTools,
# cursor .cursor/cli.json written into the worktree (excluded via info/exclude, never committed),
# grok --allow/--deny, agy flags. Nothing global is widened.
#
# Environment knobs (all optional unless marked):
#   AGENT_POOL_MAIN (required, or PR_LOOP_MAIN)  the repo's main clone
#   AGENT_POOL_REPO (or PR_LOOP_REPO)            owner/name on Gitea
#   PROVIDER_ORDER=claude          comma list; codex has a slot but is never in the default
#   AGENT_POOL_WORKER_ID           stable worker id (default <host>-pool-<mode>)
#   AGENT_POOL_STATE               leases, cooldowns, faults, runs, pool.log (~/.local/state/agent-pool)
#   AGENT_POOL_WORKTREES           where job worktrees go (default .pool-worktrees next to the clone)
#   AGENT_POOL_LEASE_TTL=900  AGENT_POOL_HEARTBEAT=300  AGENT_POOL_ORPHAN_GRACE=3600
#   AGENT_POOL_FAST_FAIL_SECS=90   AGENT_POOL_MAX_JOBS=2   WORKER_TIMEOUT=2700   DRY_RUN=1
#   AGENT_POOL_HOLD_LABELS="status: in-progress"   extra labels that read as a hold
#   AGENT_POOL_BOT                 the pool's Gitea login; any other assignee is a human hold
#   AGENT_POOL_MODEL_<PROVIDER>    model per provider (claude=opus cursor=auto grok=grok-build;
#                                  agy and codex have no default and are a setup fault without one)
#   AGENT_POOL_PROMPT_<PROVIDER>   prompt template per provider (default prompts/<mode>.generic.txt)
#   CLAUDE_BIN CURSOR_AGENT_BIN GROK_BIN AGY_BIN CODEX_BIN  full paths (default ~/.local/bin/<cli>)
#   CLAUDE_PERMISSION_MODE=auto  GROK_PERMISSION_MODE=bypassPermissions  CODEX_SANDBOX_MODE=workspace-write
#   AGY_AUTO_APPROVE=1             pass --dangerously-skip-permissions (agy has no deny list)
#   AGY_TIMEOUT=120  AGY_PRINT_TIMEOUT=100s
#
# Exit codes: 0 for a normal tick (including nothing to do); 2 for a setup fault.

set -uo pipefail

# Run from a private copy, for the reason pr-loop.sh gives: bash reads scripts by offset, and an
# edit during a long tick would otherwise land the running tick in the middle of a function.
if [ -z "${AGENT_POOL_PINNED:-}" ]; then
  AGENT_POOL_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  export AGENT_POOL_HOME
  pinned="$(mktemp -t prod-common.XXXXXX.sh)"
  cat "${BASH_SOURCE[0]}" > "$pinned"
  export AGENT_POOL_PINNED="$pinned"
  bash "$pinned" "$@"
  rc=$?
  rm -f "$pinned"
  exit $rc
fi

MODE="${1:-}"
case "$MODE" in review|resolve) ;; *) echo "usage: prod-common.sh review|resolve" >&2; exit 2 ;; esac

# ---------------------------------------------------------------- configuration
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
SCRIPTS="$(cd -- "$AGENT_POOL_HOME/../scripts" && pwd)"
COMMON="${AGENT_POOL_COMMON:-$(cd -- "$AGENT_POOL_HOME/../../skills/pr-loops-common" 2>/dev/null && pwd)}"
ADAPTER="${AGENT_POOL_ADAPTER:-$COMMON/gitea-pr.py}"
MARKER="${AGENT_POOL_MARKER:-$COMMON/marker.py}"
PROMPTS="${AGENT_POOL_PROMPTS:-$COMMON/prompts}"
REPO="${AGENT_POOL_REPO:-${PR_LOOP_REPO:-craigpars/AgileMedievalPeasantBoard}}"
MAIN="${AGENT_POOL_MAIN:-${PR_LOOP_MAIN:-}}"
STATE="${AGENT_POOL_STATE:-$HOME/.local/state/agent-pool}"
export AGENT_POOL_STATE="$STATE"
LOG="$STATE/pool.log"
RUNS="$STATE/runs"
PROVIDER_ORDER="${PROVIDER_ORDER:-claude}"
WORKER_ID="${AGENT_POOL_WORKER_ID:-$(hostname -s 2>/dev/null || echo host)-pool-$MODE}"
LEASE_TTL="${AGENT_POOL_LEASE_TTL:-900}"
HEARTBEAT="${AGENT_POOL_HEARTBEAT:-300}"
export AGENT_POOL_LEASE_TTL="$LEASE_TTL"
FAST_FAIL_SECS="${AGENT_POOL_FAST_FAIL_SECS:-90}"
MAX_JOBS="${AGENT_POOL_MAX_JOBS:-2}"
WORKER_TIMEOUT="${WORKER_TIMEOUT:-2700}"
DRY_RUN="${DRY_RUN:-0}"
EXTRA_HOLD="${AGENT_POOL_HOLD_LABELS-status: in-progress}"
BOT="${AGENT_POOL_BOT:-}"

CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
CURSOR_AGENT_BIN="${CURSOR_AGENT_BIN:-$HOME/.local/bin/cursor-agent}"
GROK_BIN="${GROK_BIN:-$HOME/.local/bin/grok}"
AGY_BIN="${AGY_BIN:-$HOME/.local/bin/agy}"
CODEX_BIN="${CODEX_BIN:-$HOME/.local/bin/codex}"

case "$MODE" in
  review)  TRIGGER="review:requested"; CLAIM="review:in-progress"; OK="review:findings"; CLEAN="review:clean" ;;
  resolve) TRIGGER="review:findings";  CLAIM="review:resolving";   OK="review:resolved"; CLEAN="" ;;
esac
FAIL="review:needs-human"
HOLD_LABELS="$CLAIM${EXTRA_HOLD:+,$EXTRA_HOLD}"

mkdir -p "$STATE" "$RUNS"
log() { printf '%s [pool:%s] %s\n' "$(date -Is)" "$MODE" "$*" | tee -a "$LOG" >&2; }
die() { log "FATAL: $*"; exit 2; }
SETUP_FAULTS=0

# ---------------------------------------------------------------- permissions
# One provider-neutral policy, translated per CLI. The deny list is what a worker may never do;
# review mode also may not stage, commit or push. Staging is by named path only.
DENY_SHELL=("git push --force*" "git push -f*" "git push * --force*" "git push * -f *" "git push --delete*"
  "git push * --delete *" "git reset --hard*" "git branch -D*" "git add -A*" "git add --all*" "git add -u*"
  "git add ." "git add . *" "git commit -a*" "git commit --all*" "git config --global*"
  "tea *" "gh *" "*gitea-pr.py label*" "*gitea-pr.py merge*" "sudo *" "rm -rf*" "systemctl *" "crontab *")
DENY_SHELL_REVIEW=("git add *" "git commit *" "git push *")
ALLOW_SHELL=("git log *" "git diff *" "git show *" "git status*" "git rev-parse *" "git merge-base *"
  "git fetch *" "git branch *" "python3 *" "node *" "cat *" "sed *" "wc *" "ls *" "head *" "tail *")
ALLOW_SHELL_RESOLVE=("git add *" "git commit *" "git push origin HEAD:*" "npm run *" "npm ci*" "npx *"
  "dotnet build*" "dotnet test*" "just *" "composer test*" "composer lint*" "php artisan test*"
  "vendor/bin/pint*" "vendor/bin/phpunit*")
# Cursor's Shell() rules match a command prefix, not a glob, so its list is spelled out.
CURSOR_DENY=("git push --force" "git push -f" "git push --delete" "git reset --hard" "git branch -D"
  "git add -A" "git add --all" "git add -u" "git add ." "git commit -a" "git commit --all"
  "git config --global" "tea" "gh" "sudo" "rm -rf" "systemctl" "crontab")
CURSOR_DENY_REVIEW=("git add" "git commit" "git push")
CURSOR_ALLOW=("git" "python3" "node" "cat" "sed" "wc" "ls" "head" "tail")
CURSOR_ALLOW_RESOLVE=("npm" "npx" "dotnet" "just" "composer" "php" "vendor/bin/pint" "vendor/bin/phpunit")

shell_deny() { printf '%s\n' "${DENY_SHELL[@]}"; [ "$MODE" = review ] && printf '%s\n' "${DENY_SHELL_REVIEW[@]}"; return 0; }
shell_allow() { printf '%s\n' "${ALLOW_SHELL[@]}"; [ "$MODE" = resolve ] && printf '%s\n' "${ALLOW_SHELL_RESOLVE[@]}"; return 0; }

model_for() { # provider
  case "$1" in
    claude) printf '%s' "${AGENT_POOL_MODEL_CLAUDE:-opus}" ;;
    cursor) printf '%s' "${AGENT_POOL_MODEL_CURSOR:-auto}" ;;
    grok)   printf '%s' "${AGENT_POOL_MODEL_GROK:-grok-build}" ;;
    agy)    printf '%s' "${AGENT_POOL_MODEL_AGY:-}" ;;
    codex)  printf '%s' "${AGENT_POOL_MODEL_CODEX:-}" ;;
  esac
}
bin_for() { # provider
  case "$1" in
    claude) printf '%s' "$CLAUDE_BIN" ;; cursor) printf '%s' "$CURSOR_AGENT_BIN" ;;
    grok) printf '%s' "$GROK_BIN" ;; agy) printf '%s' "$AGY_BIN" ;; codex) printf '%s' "$CODEX_BIN" ;;
  esac
}
prompt_for() { # provider
  local var="AGENT_POOL_PROMPT_${1^^}"
  printf '%s' "${!var:-${AGENT_POOL_PROMPT:-$PROMPTS/$MODE.generic.txt}}"
}

setup_fault() { # provider reason
  SETUP_FAULTS=$((SETUP_FAULTS + 1))
  python3 "$SCRIPTS/cooldown.py" fault --provider "$1" --reason "$2" >/dev/null 2>&1
  log "SETUP FAULT [$1]: $2 (no cooldown; fix the setup, then the provider is used again)"
}

# PROVIDERS := the providers in PROVIDER_ORDER that are not cooling down and are runnable at all.
# Runs in the calling shell (never in $(...)) so setup faults are counted.
select_providers() {
  local p bin model
  PROVIDERS=()
  for p in $(python3 "$SCRIPTS/cooldown.py" eligible --order "$PROVIDER_ORDER" 2>/dev/null); do
    case "$p" in claude|cursor|grok|agy|codex) ;; *) setup_fault "$p" "unknown provider in PROVIDER_ORDER"; continue ;; esac
    bin="$(bin_for "$p")"; model="$(model_for "$p")"
    case "$bin" in /*) ;; *) setup_fault "$p" "binary path '$bin' is not absolute"; continue ;; esac
    [ -x "$bin" ] || { setup_fault "$p" "binary $bin is missing or not executable"; continue; }
    [ -n "$model" ] || { setup_fault "$p" "no model configured (set AGENT_POOL_MODEL_${p^^})"; continue; }
    [ -f "$(prompt_for "$p")" ] || { setup_fault "$p" "missing prompt template $(prompt_for "$p")"; continue; }
    PROVIDERS+=("$p")
  done
}

# Drop providers that went into cooldown during the last job.
drop_cooling_providers() {
  local p kept=()
  for p in "${PROVIDERS[@]}"; do
    python3 "$SCRIPTS/cooldown.py" active --provider "$p" >/dev/null 2>&1 || kept+=("$p")
  done
  PROVIDERS=("${kept[@]}")
}

# Keep the pool's per-worktree tool configuration out of every commit. info/exclude is shared by
# all worktrees of the clone; skip-worktree covers a repo that already tracks .cursor/cli.json.
exclude_tool_config() { # wt
  local wt="$1" ex entry
  ex="$(git -C "$wt" rev-parse --path-format=absolute --git-path info/exclude 2>/dev/null)" || return 1
  mkdir -p "$(dirname "$ex")"; touch "$ex"
  for entry in "/.cursor/cli.json" "/.grok/"; do
    grep -qxF "$entry" "$ex" || printf '%s\n' "$entry" >> "$ex"
  done
  if git -C "$wt" ls-files --error-unmatch .cursor/cli.json >/dev/null 2>&1; then
    git -C "$wt" update-index --skip-worktree .cursor/cli.json
  fi
}

write_cursor_permissions() { # wt
  local wt="$1"
  mkdir -p "$wt/.cursor"
  {
    printf '%s\n' "${CURSOR_ALLOW[@]}" | sed 's/^/allow\tShell(/; s/$/)/'
    [ "$MODE" = resolve ] && printf '%s\n' "${CURSOR_ALLOW_RESOLVE[@]}" | sed 's/^/allow\tShell(/; s/$/)/'
    printf 'allow\tRead(**)\n'
    [ "$MODE" = resolve ] && printf 'allow\tWrite(**)\n'
    printf '%s\n' "${CURSOR_DENY[@]}" "python3 $ADAPTER label" "python3 $ADAPTER merge" | sed 's/^/deny\tShell(/; s/$/)/'
    [ "$MODE" = review ] && printf '%s\n' "${CURSOR_DENY_REVIEW[@]}" | sed 's/^/deny\tShell(/; s/$/)/'
    true
  } | python3 -c '
import json, sys
perms = {"allow": [], "deny": []}
for line in sys.stdin:
    kind, rule = line.rstrip("\n").split("\t", 1)
    perms[kind].append(rule)
json.dump({"permissions": perms}, open(sys.argv[1], "w"), indent=2)
' "$wt/.cursor/cli.json"
}

# ---------------------------------------------------------------- adapters
# build_cmd provider wt prompt-file -> sets CMD (argv) and CMD_STDIN (file fed to stdin).
# Full binary paths always; never a bare `agent`, which is Cursor's alias.
build_cmd() {
  local p="$1" wt="$2" prompt="$3" model rule
  model="$(model_for "$p")"
  CMD=(); CMD_STDIN=/dev/null
  case "$p" in
    claude)
      # The stale ANTHROPIC_API_KEY incident: never let an inherited API key pick the billing account.
      CMD=(env -u ANTHROPIC_API_KEY "$CLAUDE_BIN" -p --output-format json --model "$model"
        --permission-mode "${CLAUDE_PERMISSION_MODE:-auto}" --allowedTools Read Grep Glob)
      [ "$MODE" = resolve ] && CMD+=(Edit Write MultiEdit)
      while IFS= read -r rule; do CMD+=("Bash($rule)"); done < <(shell_allow)
      CMD+=(--disallowedTools)
      while IFS= read -r rule; do CMD+=("Bash($rule)"); done < <(shell_deny)
      CMD_STDIN="$prompt" ;;
    cursor)
      # Always --model: cursor-agent saves the model it is given as the global default.
      CMD=("$CURSOR_AGENT_BIN" -p --force --trust --workspace "$wt" --output-format stream-json
        --model "$model" "$(cat "$prompt")") ;;
    grok)
      CMD=("$GROK_BIN" --cwd "$wt" --prompt-file "$prompt" --output-format json
        --permission-mode "${GROK_PERMISSION_MODE:-bypassPermissions}")
      while IFS= read -r rule; do CMD+=(--allow "Bash($rule)"); done < <(shell_allow)
      CMD+=(--allow Read --allow Grep)
      [ "$MODE" = resolve ] && CMD+=(--allow "Edit($wt/**)" --allow "Write($wt/**)")
      while IFS= read -r rule; do CMD+=(--deny "Bash($rule)"); done < <(shell_deny)
      [ "$MODE" = review ] && CMD+=(--deny "Edit($wt/**)")
      CMD+=(-m "$model") ;;
    agy)
      CMD=(timeout "${AGY_TIMEOUT:-120}" "$AGY_BIN" -p "$(cat "$prompt")" --output-format json
        --print-timeout "${AGY_PRINT_TIMEOUT:-100s}" --model "$model")
      [ "${AGY_AUTO_APPROVE:-0}" = 1 ] && CMD+=(--dangerously-skip-permissions) ;;
    codex)
      CMD=("$CODEX_BIN" exec --ephemeral --sandbox "${CODEX_SANDBOX_MODE:-workspace-write}"
        --model "$model" --cd "$wt" -)
      CMD_STDIN="$prompt" ;;
  esac
}

# ---------------------------------------------------------------- verification
# The same gates as pr-loop.sh's verify(), with one distinction the pool needs: a missing marker
# is reported as fail-nomarker, because a fast run that left no marker is a limit, not a defect.
verify() { # pr sha headref -> ok | clean | fail-nomarker:<reason> | fail:<reason>
  local pr="$1" sha="$2" headref="$3"
  if [ "$MODE" = "review" ]; then
    local m; m="$(PR_LOOP_REPO="$REPO" python3 "$MARKER" latest "$pr" 2>/dev/null || true)"
    if [ "${m%% *}" != "$sha" ]; then echo "fail-nomarker:no review comment carrying the marker for $sha was found"; return; fi
    if [ "${m##* }" = "0" ]; then echo clean; else echo ok; fi
    return
  fi
  local newsha; newsha="$(python3 "$ADAPTER" head --repo "$REPO" --pr "$pr" 2>/dev/null)"
  if [ -z "$newsha" ]; then echo "fail:could not read the PR head after the run"; return; fi
  git -C "$MAIN" fetch origin --quiet "$headref" 2>/dev/null
  local rm; rm="$(PR_LOOP_REPO="$REPO" python3 "$MARKER" resolve "$pr" 2>/dev/null || true)"
  if [ -z "$rm" ]; then echo "fail-nomarker:the resolver left no disposition marker, so what it did to each finding is unknown"; return; fi
  local r_head r_reviewed r_fixed r_deferred r_noted
  read -r r_head r_reviewed r_fixed r_deferred r_noted <<<"$rm"
  r_noted="${r_noted:-0}"
  local review; review="$(PR_LOOP_REPO="$REPO" python3 "$MARKER" latest "$pr" 2>/dev/null || true)"
  local review_head="${review%% *}" review_count="${review##* }"
  if [ "$r_reviewed" != "$review_head" ]; then
    echo "fail:the resolver answered a review of $r_reviewed but the findings on this PR are from $review_head"; return
  fi
  if [ "$((r_fixed + r_noted + r_deferred))" -ne "${review_count:-0}" ]; then
    echo "fail:the review raised $review_count finding(s) but the resolver accounted for $((r_fixed + r_noted + r_deferred))"; return
  fi
  if [ "$r_fixed" -gt 0 ]; then
    if [ "$newsha" = "$sha" ]; then echo "fail:the resolver claims $r_fixed fix(es) but the PR head never moved"; return; fi
    if [ "$r_head" != "$newsha" ]; then echo "fail:the resolver named head $r_head but the PR is at $newsha"; return; fi
    if ! git -C "$MAIN" merge-base --is-ancestor "$sha" "$newsha"; then
      echo "fail:the PR head moved to $newsha but not as a fast-forward of $sha"; return
    fi
  elif [ "$newsha" != "$sha" ]; then
    echo "fail:the resolver claims no fixes yet the PR head moved to $newsha"; return
  fi
  if [ "$r_deferred" -gt 0 ]; then
    echo "fail:$r_deferred of $review_count finding(s) are blocking and need a human decision; $r_fixed fixed, $r_noted noted"; return
  fi
  echo ok
}

# ---------------------------------------------------------------- leases and fenced writes
JOB_PR=""; JOB_FENCE=""; JOB_WT=""; JOB_LOST=0; JOB_LOSTFILE=""; JOB_PIDFILE=""; HB_PID=""
lease() { python3 "$SCRIPTS/lease.py" "$@"; }
jlog() { log "$REPO#$JOB_PR fence=$JOB_FENCE $*"; }

# Every Gitea write: checked against the current fence under the job lock, then performed.
gwrite() { # adapter-args...
  local err rc
  err="$(lease guard --repo "$REPO" --pr "$JOB_PR" --worker "$WORKER_ID" --fence "$JOB_FENCE" \
    -- python3 "$ADAPTER" "$@" 2>&1 >/dev/null)"
  rc=$?
  if [ "$rc" -eq 4 ]; then
    JOB_LOST=1; jlog "lost the lease; write aborted ($1): ${err//$'\n'/ }"
  elif [ "$rc" -ne 0 ]; then
    jlog "warning: gitea $1 failed: ${err//$'\n'/ }"
  fi
  return "$rc"
}
relabel() { # remove add
  if [ "$DRY_RUN" = "1" ]; then jlog "DRY: $1 -> $2"; return 0; fi
  gwrite label --repo "$REPO" --pr "$JOB_PR" --remove "$1" --add "$2"
}
comment() { # body
  local bf rc; bf="$(mktemp)"; printf '%s\n' "$1" > "$bf"
  gwrite comment --repo "$REPO" --pr "$JOB_PR" --body-file "$bf"; rc=$?
  rm -f "$bf"; return "$rc"
}

heartbeat_start() {
  local parent=$$
  JOB_LOSTFILE="$RUNS/lost-$JOB_PR-$JOB_FENCE"; JOB_PIDFILE="$RUNS/pid-$JOB_PR-$JOB_FENCE"
  rm -f "$JOB_LOSTFILE" "$JOB_PIDFILE"
  (
    while sleep "$HEARTBEAT"; do
      # A heartbeat that outlives its tick would keep a dead run's lease alive forever.
      kill -0 "$parent" 2>/dev/null || exit 0
      if ! lease renew --repo "$REPO" --pr "$JOB_PR" --worker "$WORKER_ID" --fence "$JOB_FENCE" 2>>"$LOG"; then
        : > "$JOB_LOSTFILE"
        pid="$(cat "$JOB_PIDFILE" 2>/dev/null)"; [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
        exit 0
      fi
    done
  ) &
  HB_PID=$!
}
heartbeat_stop() {
  [ -n "$HB_PID" ] && { pkill -P "$HB_PID" 2>/dev/null; kill "$HB_PID" 2>/dev/null; wait "$HB_PID" 2>/dev/null; }
  HB_PID=""
}
still_held() {
  [ ! -f "$JOB_LOSTFILE" ] && lease check --repo "$REPO" --pr "$JOB_PR" --worker "$WORKER_ID" --fence "$JOB_FENCE" 2>/dev/null
}

remove_worktree() { # wt [--force]
  [ -n "$1" ] && [ -d "$1" ] || return 0
  git -C "$MAIN" worktree remove ${2:-} "$1" >/dev/null 2>&1 || jlog "worktree $1 kept (uncommitted changes or busy); inspect and remove by hand"
}

end_job() { # outcome; drops the lease and local state, whether or not the writes went through
  heartbeat_stop
  if [ "$JOB_LOST" -eq 0 ]; then
    lease release --repo "$REPO" --pr "$JOB_PR" --worker "$WORKER_ID" --fence "$JOB_FENCE" --outcome "$1" 2>>"$LOG" \
      || jlog "release refused; the lease had already moved on"
  fi
  remove_worktree "$JOB_WT"
  rm -f "$JOB_LOSTFILE" "$JOB_PIDFILE"
  JOB_PR=""; JOB_FENCE=""; JOB_WT=""; JOB_LOST=0
}

finish_job() { # outcome(ok|clean|fail|trigger) reason
  local outcome="$1" reason="$2"
  case "$outcome" in
    ok)      relabel "$CLAIM" "$OK" ;;
    clean)   relabel "$CLAIM" "$CLEAN" ;;
    trigger) relabel "$CLAIM" "$TRIGGER" ;;
    fail)    relabel "$CLAIM" "$FAIL" && [ "$JOB_LOST" -eq 0 ] && \
               comment "Automated $MODE pool stopped on this PR: $reason. A human needs to look; the pool log on the review host has the detail." ;;
  esac
  jlog "$outcome ($reason)"
  end_job "$outcome"
}

on_exit() {
  local rc=$?
  if [ -n "$JOB_FENCE" ]; then
    local pid; pid="$(cat "$JOB_PIDFILE" 2>/dev/null)"; [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
    [ "$JOB_LOST" -eq 0 ] && finish_job trigger "the pool tick exited unexpectedly (exit $rc) while holding the job"
  fi
  heartbeat_stop
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------- one provider attempt
prepare_worktree() { # sha headref -> sets JOB_WT
  JOB_WT="$WT_ROOT/pool-$MODE-$JOB_PR-f$JOB_FENCE"
  git -C "$MAIN" fetch origin --quiet "$2" 2>/dev/null || { jlog "fetch $2 failed"; return 1; }
  [ -d "$JOB_WT" ] && git -C "$MAIN" worktree remove --force "$JOB_WT" >/dev/null 2>&1
  git -C "$MAIN" worktree add --detach "$JOB_WT" "$1" >/dev/null 2>&1 || { jlog "worktree add failed"; return 1; }
  exclude_tool_config "$JOB_WT"
}

render_prompt() { # provider sha headref base report -> prompt file path
  local out="$RUNS/prompt-$JOB_PR-f$JOB_FENCE-$1.txt"
  sed -e "s|__PR__|$JOB_PR|g" -e "s|__HEADREF__|$3|g" -e "s|__SHA__|$2|g" -e "s|__BASE__|$4|g" \
      -e "s|__REPO__|$REPO|g" -e "s|__ADAPTER__|$ADAPTER|g" -e "s|__COMMON__|$COMMON|g" \
      -e "s|__REPORT__|$5|g" -e "s|__SENTINEL__|POOL_RUN_DONE|g" "$(prompt_for "$1")" > "$out"
  printf '%s' "$out"
}

# attempt provider sha headref base -> sets VERDICT (ok clean fail setup limit lost) and DETAIL.
# Runs in the calling shell: it sets JOB_WT and may record setup faults.
attempt() {
  local p="$1" sha="$2" headref="$3" base="$4" prompt report out err rc t0 elapsed cls v
  VERDICT=""; DETAIL=""
  prepare_worktree "$sha" "$headref" || { VERDICT=setup; DETAIL="could not prepare a worktree at $sha"; return; }
  [ "$p" = cursor ] && write_cursor_permissions "$JOB_WT"
  report="$RUNS/report-$JOB_PR-f$JOB_FENCE-$p.md"; rm -f "$report"
  prompt="$(render_prompt "$p" "$sha" "$headref" "$base" "$report")"
  out="$RUNS/out-$JOB_PR-f$JOB_FENCE-$p.json"; err="$RUNS/err-$JOB_PR-f$JOB_FENCE-$p.txt"
  build_cmd "$p" "$JOB_WT" "$prompt"
  jlog "spawning $p (model $(model_for "$p")) in $JOB_WT at $sha"
  t0="$(date +%s)"
  ( cd "$JOB_WT" && exec timeout -k 30 "$WORKER_TIMEOUT" "${CMD[@]}" <"$CMD_STDIN" >"$out" 2>"$err" ) &
  echo $! > "$JOB_PIDFILE"
  wait $!; rc=$?
  rm -f "$JOB_PIDFILE"
  elapsed=$(( $(date +%s) - t0 ))
  if ! still_held; then VERDICT=lost; DETAIL="$p ran ${elapsed}s but the lease moved on"; return; fi
  cls="$(python3 "$SCRIPTS/classify.py" --provider "$p" --exit "$rc" --stdout "$out" --stderr "$err")"
  v="$(verify "$JOB_PR" "$sha" "$headref")"
  jlog "$p exited $rc after ${elapsed}s; provider says ${cls%%$'\t'*}; verification says ${v%%:*}"
  case "$v" in
    ok|clean)
      # The verified outcome stands either way; the provider's own complaint is still recorded.
      case "$cls" in
        setup*) setup_fault "$p" "${cls#*$'\t'} (the run still verified, so its outcome stands)" ;;
        limit*) python3 "$SCRIPTS/cooldown.py" record --provider "$p" --reason "${cls#*$'\t'}" >/dev/null ;;
        *)      python3 "$SCRIPTS/cooldown.py" clear --provider "$p" ;;
      esac
      VERDICT="$v"; DETAIL="$p verified"; return ;;
  esac
  case "$cls" in
    setup*) VERDICT=setup; DETAIL="${cls#*$'\t'}"; return ;;
    limit*) VERDICT=limit; DETAIL="${cls#*$'\t'}"; return ;;
  esac
  if [ "${v%%:*}" = "fail-nomarker" ] && [ "$elapsed" -lt "$FAST_FAIL_SECS" ]; then
    VERDICT=limit; DETAIL="$p ended after ${elapsed}s (under ${FAST_FAIL_SECS}s) with no marker comment: ${cls#*$'\t'}"
    return
  fi
  VERDICT=fail; DETAIL="${v#*:} ($p, ${elapsed}s)"
}

# ---------------------------------------------------------------- one job
run_job() { # pr headref sha base reclaim(0|1) providers...
  local pr="$1" headref="$2" sha="$3" base="$4" reclaim="$5"; shift 5
  local fence remove p tried=()
  fence="$(lease claim --repo "$REPO" --pr "$pr" --mode "$MODE" --worker "$WORKER_ID" --provider "${1:-}" 2>>"$LOG")" \
    || { log "$REPO#$pr: lease is held elsewhere; skipping"; return 0; }
  JOB_PR="$pr"; JOB_FENCE="$fence"; JOB_LOST=0; JOB_WT=""
  remove="$TRIGGER"
  [ "$reclaim" = 1 ] && remove="$TRIGGER${EXTRA_HOLD:+,$EXTRA_HOLD}"
  if ! relabel "$remove" "$CLAIM"; then
    jlog "claim relabel failed; leaving the PR for a later tick"
    end_job claim-failed; return 0
  fi
  if [ "$reclaim" = 1 ]; then jlog "claimed by $WORKER_ID (reclaimed a dead hold)"; else jlog "claimed by $WORKER_ID"; fi
  heartbeat_start

  if [ "$reclaim" = 1 ]; then
    local before; before="$(verify "$pr" "$sha" "$headref")"
    case "$before" in ok|clean) finish_job "$before" "the previous run's work was already verified at $sha"; return 0 ;; esac
  fi

  for p in "$@"; do
    attempt "$p" "$sha" "$headref" "$base"
    tried+=("$p=$VERDICT")
    case "$VERDICT" in
      ok|clean) finish_job "$VERDICT" "$DETAIL"; return 0 ;;
      lost)     JOB_LOST=1; jlog "$DETAIL; touching nothing on Gitea"; end_job lost; return 0 ;;
      fail)     finish_job fail "$DETAIL"; return 0 ;;
      setup)    setup_fault "$p" "$DETAIL" ;;
      limit)
        local cd; cd="$(python3 "$SCRIPTS/cooldown.py" record --provider "$p" --reason "$DETAIL")"
        jlog "LIMIT [$p]: $DETAIL; cooling down $(( ${cd#*$'\t'} / 60 ))m"
        if [ "$MODE" = resolve ] && [ "$(python3 "$ADAPTER" head --repo "$REPO" --pr "$pr" 2>/dev/null)" != "$sha" ]; then
          finish_job trigger "the head moved during a limited run; not handing a half-done resolve to another provider"
          return 0
        fi ;;
    esac
    remove_worktree "$JOB_WT" --force; JOB_WT=""
  done
  finish_job trigger "no provider completed the job (${tried[*]:-none eligible}); back in the queue"
}

# ---------------------------------------------------------------- the tick
[ -n "$COMMON" ] && [ -d "$COMMON" ] || die "cannot find skills/pr-loops-common (set AGENT_POOL_COMMON)"
[ -f "$ADAPTER" ] || die "missing Gitea adapter: $ADAPTER"
[ -f "$MARKER" ] || die "missing marker reader: $MARKER"
[ -n "$MAIN" ] && [ -e "$MAIN/.git" ] || die "no checkout for $REPO: set AGENT_POOL_MAIN to its clone (got '$MAIN')"
[ "$HEARTBEAT" -lt "$LEASE_TTL" ] || die "AGENT_POOL_HEARTBEAT ($HEARTBEAT) must be shorter than AGENT_POOL_LEASE_TTL ($LEASE_TTL)"
WT_ROOT="${AGENT_POOL_WORKTREES:-$(dirname "$MAIN")/.pool-worktrees}"
mkdir -p "$WT_ROOT"

exec 9>"$STATE/pool-$MODE-$(printf '%s' "$REPO" | tr -c 'A-Za-z0-9.-' '_').lock"
if ! flock -n 9; then log "previous $MODE tick for $REPO still running; exiting"; exit 0; fi

select_providers
if [ "${#PROVIDERS[@]}" -eq 0 ]; then
  log "no eligible provider in '$PROVIDER_ORDER' (cooling down or misconfigured); claiming nothing"
  [ "$SETUP_FAULTS" -gt 0 ] && exit 2
  exit 0
fi

git -C "$MAIN" fetch origin --quiet --prune 2>/dev/null || log "warning: fetch failed; continuing with what is local"

# Candidates carry the trigger label (fresh work) or the claim label (a hold that may have died).
if ! LISTING="$(python3 "$ADAPTER" list --repo "$REPO" --state open | TRIGGER="$TRIGGER" CLAIM="$CLAIM" python3 -c '
import json, os, re, sys
trigger, claim = os.environ["TRIGGER"], os.environ["CLAIM"]
raw = os.environ.get("PR_LOOP_SKIP_PATTERN", r"docblock-backfill|^chore\(#152\)")
rx = re.compile(raw) if raw else None
for pr in json.load(sys.stdin):
    labels = pr["labels"]
    if trigger not in labels and claim not in labels: continue
    if pr["draft"] or pr["is_bot"]: continue
    if rx and (rx.search(pr["title"]) or rx.search(pr["head_ref"])): continue
    print("\t".join([str(pr["number"]), pr["head_ref"], pr["head_sha"], pr["base_ref"],
                     json.dumps(labels), json.dumps(pr.get("assignees", []))]))
')"; then
  die "gitea pr list failed; not treating that as an empty queue"
fi
mapfile -t CANDIDATES < <(printf '%s\n' "$LISTING" | sed '/^$/d')
[ "${#CANDIDATES[@]}" -eq 0 ] && { log "no open PR in $REPO carries $TRIGGER or $CLAIM"; exit 0; }

# Resolve-mode findings for an older head go back to review, under a lease like any other write.
send_back_for_review() { # pr reason
  local fence
  fence="$(lease claim --repo "$REPO" --pr "$1" --mode "$MODE" --worker "$WORKER_ID" 2>>"$LOG")" || return 0
  JOB_PR="$1"; JOB_FENCE="$fence"; JOB_LOST=0; JOB_WT=""
  relabel "$TRIGGER" "review:requested"
  jlog "$2; sent back to review:requested"
  end_job stale-findings
}

QUEUE=()
for row in "${CANDIDATES[@]}"; do
  IFS=$'\t' read -r pr headref sha base labels assignees <<<"$row"
  hold="$(lease hold --repo "$REPO" --pr "$pr" --labels "$labels" --assignees "$assignees" \
    --hold-labels "$HOLD_LABELS" --bot "$BOT" 2>>"$LOG")"
  state="${hold%%$'\t'*}"; why="${hold#*$'\t'}"
  reclaim=0
  case "$state" in
    free)    ;;
    expired|orphan-expired) reclaim=1; log "$REPO#$pr: dead hold ($why); reclaiming" ;;
    live)    log "$REPO#$pr: held by a live bot lease ($why); skipping"; continue ;;
    human)   log "$REPO#$pr: held by a human ($why); skipping"; continue ;;
    orphan-pending) log "$REPO#$pr: hold with no live lease ($why); not a human hold, waiting out the grace"; continue ;;
    *)       log "$REPO#$pr: could not read the hold state; skipping"; continue ;;
  esac
  if [ "$reclaim" = 0 ]; then
    marker="$(PR_LOOP_REPO="$REPO" python3 "$MARKER" latest "$pr" 2>/dev/null || true)"
    mhead="${marker%% *}"
    if [ "$MODE" = review ] && [ "$mhead" = "$sha" ]; then log "$REPO#$pr head $sha already reviewed (marker); skipping"; continue; fi
    if [ "$MODE" = resolve ] && [ "$mhead" != "$sha" ]; then
      if [ "$DRY_RUN" = 1 ]; then log "DRY: $REPO#$pr findings are stale; would send back to review:requested"
      else send_back_for_review "$pr" "findings are for $mhead but head is $sha"; fi
      continue
    fi
  fi
  QUEUE+=("$pr"$'\t'"$headref"$'\t'"$sha"$'\t'"$base"$'\t'"$reclaim")
done
[ "${#QUEUE[@]}" -eq 0 ] && { log "nothing to do after skips"; [ "$SETUP_FAULTS" -gt 0 ] && exit 2; exit 0; }

jobs_run=0
for row in "${QUEUE[@]}"; do
  [ "$jobs_run" -ge "$MAX_JOBS" ] && break
  IFS=$'\t' read -r pr headref sha base reclaim <<<"$row"
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY: would claim $REPO#$pr at $sha (reclaim=$reclaim) with providers ${PROVIDERS[*]}"
  else
    run_job "$pr" "$headref" "$sha" "$base" "$reclaim" "${PROVIDERS[@]}"
    drop_cooling_providers
    [ "${#PROVIDERS[@]}" -eq 0 ] && { log "every provider is cooling down; stopping the tick"; break; }
  fi
  jobs_run=$((jobs_run + 1))
done
log "tick complete ($jobs_run job(s))"
[ "$SETUP_FAULTS" -gt 0 ] && exit 2
exit 0
