#!/usr/bin/env bash
# prod-common.sh
#
# One tick of the provider-parameterized PR worker pool for one Gitea repo (issue #1).
#
# Labels (all overridable, see below):
#
#   agent:ready -> agent:claimed -> agent:done | agent:ready | agent:needs-human
#
# The job kind is derived per PR from its markers; there is no mode argument:
#   * a review marker for the current head with findings > 0          -> resolve
#   * a review marker for the current head with no findings, or a resolve marker that already
#     answered the latest review at the current head                  -> settled without a provider
#   * anything else                                                   -> review
# A review with findings goes back to agent:ready (queued for resolve); a clean review and a
# verified resolve go to agent:done; a real verification failure goes to agent:needs-human with a
# comment; a limit, a timeout or no provider completing goes back to agent:ready.
#
# Claims (scripts/claim-record.py): one write-once record per PR keyed by attempt_id, carrying
# an absolute expected_deadline_at computed at claim time. Nothing renews it. Every label write,
# comment and push runs through `claim-record.py guard|release`, which re-reads the record under
# the job lock and refuses if this attempt is no longer current. A provider fallback inside a
# job is a new attempt (reattempt), so the record always names the provider actually running.
# Each tick reconciles claimed PRs against live labels (issue #1's table): a claim past its
# deadline is requeued and its provider cooled down, a claimed label with no record goes to
# agent:needs-human, and a record with no claimed label is dropped.
#
# Workers never publish. They read, edit and commit in a detached worktree and write a report
# file (or, when they cannot write files, end with the report as their final response). The
# controller then checks the claim is still held, validates the report's marker, pushes
# HEAD:refs/heads/<headref> as a fast-forward (never a protected branch, never a + refspec) and
# posts the report, all through the claim guard. Workers run in their own process group
# (setsid) with remote.origin.pushurl overridden to a dead path, and a read-only watcher kills
# the whole group as soon as the claim is superseded.
#
# Limits are a cooldown, never a needs-human: scripts/classify.py's signatures, plus a run that
# ends inside AGENT_POOL_FAST_FAIL_SECS without a marker (the 32-second credit wall). Setup
# faults (a permission the pool's own policy denied, a missing binary or model) get no cooldown:
# a SETUP FAULT log line, faults/<provider>.json, and exit 2 at the end of the tick.
#
# Permissions come from scripts/policy.py, per worktree and per invocation only: claude
# --allowedTools/--disallowedTools, cursor .cursor/cli.json in the worktree (no --force), grok
# --allow/--deny. agy has no rule list: it reviews in --mode plan and is only eligible for
# resolve with AGY_AUTO_APPROVE=1. codex also has no rule list, by owner decision (PR #2
# review, Spec 1): --sandbox workspace-write has no network and confines writes to the
# worktree, so the pushurl override and controller-only publication contain it instead. The
# sandbox does not stop reads; the report and pre-push secret scans contain what it reads. The
# exemption holds only for CODEX_SANDBOX_MODE=workspace-write or read-only.
# Nothing global is widened.
#
# Environment knobs (all optional unless marked):
#   AGENT_POOL_MAIN (required, or PR_LOOP_MAIN)  the repo's main clone
#   AGENT_POOL_REPO (or PR_LOOP_REPO)            owner/name on Gitea
#   PROVIDER_ORDER=claude          comma list; codex has a slot but is never in the default
#   AGENT_POOL_WORKER_ID           stable worker id (default <host>-pool)
#   AGENT_POOL_STATE               claims, cooldowns, faults, runs, pool.log (~/.local/state/agent-pool)
#   AGENT_POOL_WORKTREES           where job worktrees go (default .pool-worktrees next to the clone)
#   AGENT_POOL_LABEL_READY=agent:ready  AGENT_POOL_LABEL_CLAIMED=agent:claimed
#   AGENT_POOL_LABEL_DONE=agent:done    AGENT_POOL_LABEL_NEEDS_HUMAN=agent:needs-human
#   AGENT_POOL_DEADLINE_SECS=2700  a claim's expected_deadline_at, seeded once per attempt
#   WORKER_TIMEOUT=2400            per provider run; must be shorter than the deadline
#   AGENT_POOL_WATCH_SECS=30       how often the watcher re-reads the claim during a run
#   AGENT_POOL_ORPHAN_GRACE=3600   AGENT_POOL_FAST_FAIL_SECS=90   AGENT_POOL_MAX_JOBS=2   DRY_RUN=1
#   AGENT_POOL_HEAD_SETTLE="1 2 3 4"   backoff (s) while Gitea's PR head catches up with a push
#   AGENT_POOL_TIMEOUT_COOLDOWN=900    a timed-out provider pauses this long (no strike); the job
#                                      falls through to the next provider
#   AGENT_POOL_HOLD_LABELS="status: in-progress"   extra labels that read as a hold
#   AGENT_POOL_NIGHTCREW_HOLD=1    for a repo shared with TheNightCrew: before each claim, ask its
#                                  GET <api>/repos/<repo>/issue-hold (scripts/nightcrew-issue-hold.py)
#                                  and claim nothing more this tick unless the answer is exactly
#                                  clear. Any failure (no token, HTTP error, timeout, bad answer,
#                                  a crashed or hung check) also claims nothing. Unset, 0, off,
#                                  false or no (default): no check -- most repos aren't shared.
#                                  Any other value turns it on.
#   AGENT_POOL_NIGHTCREW_URL       the NightCrew API base including /api (else NIGHT_CREW_URL,
#                                  else http://localhost:8771/api)
#   AGENT_POOL_NIGHTCREW_TOKEN_FILE  file holding a NightCrew Worker token whose served_repos
#                                  include this repo (default ~/.config/pulse/night_crew_token)
#   AGENT_POOL_NIGHTCREW_TIMEOUT=10  seconds per request; the whole check is cut off at 2x+3
#                                  The answer is a snapshot, not a cross-system mutex: an issue
#                                  job TheNightCrew claims right after a clear answer still
#                                  overlaps, so TheNightCrew's own ClaimNextJob::blockReason and
#                                  this pool's claim records both stay in force.
#   AGENT_POOL_NIGHTCREW_BOT       deprecated (the old Gitea bot-assignee proxy, now removed).
#                                  Still set, it turns the endpoint check on, even over
#                                  AGENT_POOL_NIGHTCREW_HOLD=0, and logs a warning each tick;
#                                  replace it with AGENT_POOL_NIGHTCREW_HOLD=1 plus a Worker token.
#   AGENT_POOL_PROTECTED_BRANCHES=develop,main,master,release   never pushed to (nor release/*)
#   AGENT_POOL_BOT                 the pool's Gitea login; any other assignee is a human hold
#   AGENT_POOL_MODEL_<PROVIDER>    model per provider (claude=opus cursor=auto grok=grok-build;
#                                  agy runs on its own default without one; codex is a setup fault)
#   AGENT_POOL_PROMPT_<PROVIDER>_<JOB>   prompt template (default prompts/<job>.generic.txt)
#   CLAUDE_BIN CURSOR_AGENT_BIN GROK_BIN AGY_BIN CODEX_BIN  full paths (default ~/.local/bin/<cli>)
#   CLAUDE_PERMISSION_MODE=default  GROK_PERMISSION_MODE=dontAsk  CODEX_SANDBOX_MODE=workspace-write
#   AGY_AUTO_APPROVE=1             let agy take resolve jobs (--dangerously-skip-permissions)
#   AGY_PRINT_TIMEOUT=0            agy's own print timeout; 0 leaves WORKER_TIMEOUT as the only limit
#   AGENT_POOL_GATE_BUDGET=1200    cap (s) on any manifest's gate budget; a job's gates also stop
#                                  60s before its claim deadline
#   AGENT_POOL_GATES_DIR           controller-owned manifest overrides (~/.config/agent-pool/gates)
#   AGENT_POOL_GATE_RO_BINDS       colon list of toolchain dirs bound read-only into the gate sandbox
#   AGENT_POOL_GATE_SANDBOX AGENT_POOL_GATE_SCOPE   bwrap and systemd-run paths (default: /usr/bin)
#   AGENT_POOL_ABILITIES           comma list of the abilities this repo grants (plan, review,
#                                  prototype, test-author, resolve); a job kind runs only if its
#                                  ability is listed, and agy never resolves, AGY_AUTO_APPROVE or
#                                  not. Set by the entrypoints; unset keeps review and resolve.
#
# Entrypoint mode: bin/prod-<provider>.sh sets AGENT_POOL_PROVIDER and sources this file. It then
# runs one tick per repo that repos.toml (scripts/repoconfig.py, AGENT_POOL_CONFIG) enables for
# that provider, each with PROVIDER_ORDER=<provider>, AGENT_POOL_ABILITIES from the config,
# AGY_AUTO_APPROVE unset, AGENT_POOL_WORKER_ID defaulting to <host>-<provider>, and
# AGENT_POOL_NIGHTCREW_HOLD=1 where the repo sets nightcrew_hold. With AGENT_POOL_REPO set, only
# that repo is ticked.
#
# Gates (scripts/gates.py, docs/plans/controller-gates.md): workers run no gate. After a resolve
# worker has exited and before anything is pushed, the controller loads the gate manifest from
# the PR's base branch by blob (or a controller-owned override), refuses commits that change
# gate-defining files, checks the worker's commit out by SHA into a fresh directory with no
# .git, and runs the selected gates there in a sandbox with no network, home, ssh agent or
# tokens. The result is a write-once receipt bound to the attempt and the exact head; the push
# goes ahead only for a receipt that passed. A red gate is a needs-human with nothing pushed; a
# broken sandbox or manifest is a setup fault [gates] that requeues the job and pauses resolve
# jobs until a person fixes it and deletes faults/gates.json.
#
# Exit codes: 0 for a normal tick (including nothing to do); 2 for a setup fault.

set -uo pipefail

# forward_signals cmd...: run cmd as a child and pass TERM (and INT, as TERM: a non-interactive
# shell's background child ignores INT) on to it. systemd's KillMode=mixed signals only the main
# process, which is a wrapper here; the tick below it must still get TERM and run its exit trap.
fwd_stopped=0
forward_signals() {
  local fwd_rc
  "$@" &
  fwd_child=$!
  trap 'fwd_stopped=1; kill -TERM "$fwd_child" 2>/dev/null' TERM INT
  while :; do
    wait "$fwd_child"; fwd_rc=$?
    kill -0 "$fwd_child" 2>/dev/null || break
  done
  trap - TERM INT
  return "$fwd_rc"
}

if [ -n "${AGENT_POOL_PROVIDER:-}" ]; then
  # Sourced by an entrypoint, possibly under set -e: every command below tolerates failure.
  entry_provider="$AGENT_POOL_PROVIDER"
  entry_self="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
  export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
  entry_log() { printf '%s [prod-%s] %s\n' "$(date -Is)" "$entry_provider" "$*" >&2; }
  case "$entry_provider" in claude|cursor|grok|agy|codex) ;; *) entry_log "unknown provider"; exit 2 ;; esac
  [ "$#" -eq 0 ] || { echo "usage: prod-$entry_provider.sh (no arguments; repos come from repos.toml)" >&2; exit 2; }
  if ! entry_ticks="$(python3 "$(dirname -- "$entry_self")/../scripts/repoconfig.py" ticks --provider "$entry_provider")"; then
    entry_log "the repo config is unusable; ticking nothing"
    exit 2
  fi
  entry_worker="${AGENT_POOL_WORKER_ID:-$(hostname -s 2>/dev/null || echo host)-$entry_provider}"
  entry_rc=0
  while IFS=$'\t' read -r entry_repo entry_main entry_abilities entry_hold; do
    [ -n "$entry_repo" ] || continue
    entry_env=(-u AGENT_POOL_PROVIDER -u AGY_AUTO_APPROVE AGENT_POOL_REPO="$entry_repo" AGENT_POOL_MAIN="$entry_main"
      AGENT_POOL_ABILITIES="$entry_abilities" PROVIDER_ORDER="$entry_provider" AGENT_POOL_WORKER_ID="$entry_worker")
    [ "$entry_hold" = 1 ] && entry_env+=(AGENT_POOL_NIGHTCREW_HOLD=1)
    entry_log "$entry_repo: tick as $entry_worker with abilities $entry_abilities"
    rc=0
    forward_signals env "${entry_env[@]}" bash "$entry_self" </dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
      entry_log "$entry_repo: tick exited $rc"
      [ "$entry_rc" -eq 2 ] || entry_rc="$rc"
    fi
    if [ "$fwd_stopped" = 1 ]; then entry_log "stopped; ticking no further repos"; exit 143; fi
  done <<<"$entry_ticks"
  exit "$entry_rc"
fi

# Run from a private copy, for the reason pr-loop.sh gives: bash reads scripts by offset, and an
# edit during a long tick would otherwise land the running tick in the middle of a function.
if [ -z "${AGENT_POOL_PINNED:-}" ]; then
  AGENT_POOL_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  export AGENT_POOL_HOME
  pinned="$(mktemp -t prod-common.XXXXXX.sh)"
  cat "${BASH_SOURCE[0]}" > "$pinned"
  export AGENT_POOL_PINNED="$pinned"
  rc=0
  forward_signals bash "$pinned" "$@" || rc=$?
  rm -f "$pinned"
  exit $rc
fi

[ "$#" -eq 0 ] || { echo "usage: prod-common.sh (no arguments; the job kind is derived per PR)" >&2; exit 2; }

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
WORKER_ID="${AGENT_POOL_WORKER_ID:-$(hostname -s 2>/dev/null || echo host)-pool}"
DEADLINE_SECS="${AGENT_POOL_DEADLINE_SECS:-2700}"
export AGENT_POOL_DEADLINE_SECS="$DEADLINE_SECS"
WATCH_SECS="${AGENT_POOL_WATCH_SECS:-30}"
FAST_FAIL_SECS="${AGENT_POOL_FAST_FAIL_SECS:-90}"
MAX_JOBS="${AGENT_POOL_MAX_JOBS:-2}"
WORKER_TIMEOUT="${WORKER_TIMEOUT:-2400}"
HEAD_SETTLE="${AGENT_POOL_HEAD_SETTLE:-1 2 3 4}"
TIMEOUT_COOLDOWN="${AGENT_POOL_TIMEOUT_COOLDOWN:-900}"
GATE_BUDGET="${AGENT_POOL_GATE_BUDGET:-1200}"
export AGENT_POOL_GATE_BUDGET="$GATE_BUDGET"
DRY_RUN="${DRY_RUN:-0}"
EXTRA_HOLD="${AGENT_POOL_HOLD_LABELS-status: in-progress}"
BOT="${AGENT_POOL_BOT:-}"
READY="${AGENT_POOL_LABEL_READY:-agent:ready}"
CLAIMED="${AGENT_POOL_LABEL_CLAIMED:-agent:claimed}"
DONE="${AGENT_POOL_LABEL_DONE:-agent:done}"
HUMAN="${AGENT_POOL_LABEL_NEEDS_HUMAN:-agent:needs-human}"
# Opt-in per repo, since most repos this pool runs against aren't tracked by TheNightCrew. Only
# the explicit off words disable it, so a typo cannot silently drop the protection.
NIGHTCREW_LEGACY_BOT="${AGENT_POOL_NIGHTCREW_BOT:-}"
case "$(printf '%s' "${AGENT_POOL_NIGHTCREW_HOLD:-}" | tr '[:upper:]' '[:lower:]')" in
  ""|0|off|false|no) NIGHTCREW_CHECK=0 ;;
  *) NIGHTCREW_CHECK=1 ;;
esac
[ -n "$NIGHTCREW_LEGACY_BOT" ] && NIGHTCREW_CHECK=1
NIGHTCREW_TIMEOUT="${AGENT_POOL_NIGHTCREW_TIMEOUT:-10}"
NIGHTCREW_HOLD_SCRIPT="${AGENT_POOL_NIGHTCREW_HOLD_SCRIPT:-$SCRIPTS/nightcrew-issue-hold.py}"
PROTECTED="${AGENT_POOL_PROTECTED_BRANCHES:-develop,main,master,release}"
ABILITIES_SET=0; ABILITIES=""
if [ -n "${AGENT_POOL_ABILITIES+x}" ]; then ABILITIES_SET=1; ABILITIES="$AGENT_POOL_ABILITIES"; fi
NOPUSH_URL="/nonexistent/agent-pool-workers-never-push"
CONTEXT_FILE=".agent-pool-context.md"

CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
CURSOR_AGENT_BIN="${CURSOR_AGENT_BIN:-$HOME/.local/bin/cursor-agent}"
GROK_BIN="${GROK_BIN:-$HOME/.local/bin/grok}"
AGY_BIN="${AGY_BIN:-$HOME/.local/bin/agy}"
CODEX_BIN="${CODEX_BIN:-$HOME/.local/bin/codex}"

PUBLISHED="$STATE/published"
mkdir -p "$STATE" "$RUNS" "$PUBLISHED"
log() { printf '%s [pool] %s\n' "$(date -Is)" "$*" | tee -a "$LOG" >&2; }
die() { log "FATAL: $*"; exit 2; }
slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9.-' '_'; }
SETUP_FAULTS=0

# ---------------------------------------------------------------- providers
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
prompt_for() { # provider job
  local var="AGENT_POOL_PROMPT_${1^^}_${2^^}" def="$PROMPTS/$2.generic.txt"
  # agy reviews in plan mode, where every command is denied.
  [ "$1/$2" = agy/review ] && def="$PROMPTS/review.agy.txt"
  printf '%s' "${!var:-$def}"
}

setup_fault() { # provider reason
  SETUP_FAULTS=$((SETUP_FAULTS + 1))
  python3 "$SCRIPTS/cooldown.py" fault --provider "$1" --reason "$2" >/dev/null 2>&1
  log "SETUP FAULT [$1]: $2 (no cooldown; fix the setup, then the provider is used again)"
}

# PROVIDERS := the providers in PROVIDER_ORDER that are not cooling down and are runnable at all.
# Runs in the calling shell (never in $(...)) so setup faults are counted.
select_providers() {
  local p bin model job
  PROVIDERS=()
  for p in $(python3 "$SCRIPTS/cooldown.py" eligible --order "$PROVIDER_ORDER" 2>/dev/null); do
    case "$p" in claude|cursor|grok|agy|codex) ;; *) setup_fault "$p" "unknown provider in PROVIDER_ORDER"; continue ;; esac
    bin="$(bin_for "$p")"; model="$(model_for "$p")"
    case "$bin" in /*) ;; *) setup_fault "$p" "binary path '$bin' is not absolute"; continue ;; esac
    [ -x "$bin" ] || { setup_fault "$p" "binary $bin is missing or not executable"; continue; }
    [ -n "$model" ] || [ "$p" = agy ] || { setup_fault "$p" "no model configured (set AGENT_POOL_MODEL_${p^^})"; continue; }
    for job in review resolve; do
      [ -f "$(prompt_for "$p" "$job")" ] || { setup_fault "$p" "missing prompt template $(prompt_for "$p" "$job")"; continue 2; }
    done
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

ability_enabled() { # job
  [ "$ABILITIES_SET" = 0 ] || [[ ",$ABILITIES," == *",$1,"* ]]
}

# JOB_PROVIDERS := PROVIDERS that may take a job of this kind. agy has no deny list, so it only
# resolves when an operator running this tick directly opted in to it unattended; under an
# entrypoint (AGENT_POOL_ABILITIES set) it never resolves.
job_providers() { # job
  local p
  JOB_PROVIDERS=()
  ability_enabled "$1" || return 0
  # Another provider would only hit the same broken sandbox after a full WORKER_TIMEOUT.
  if [ "$1" = resolve ] && [ -e "$STATE/faults/gates.json" ]; then
    log "$REPO: resolve jobs are paused: the gate sandbox has a recorded fault ($STATE/faults/gates.json); fix it, then delete that file"
    return 0
  fi
  for p in "${PROVIDERS[@]}"; do
    [ "$1" = resolve ] && [ "$p" = agy ] && { [ "${AGY_AUTO_APPROVE:-0}" != 1 ] || [ "$ABILITIES_SET" = 1 ]; } && continue
    JOB_PROVIDERS+=("$p")
  done
}

# The only refs the controller pushes are refs/heads/<headref> for an ordinary feature branch.
headref_safe() { # headref
  local h="$1" b prot
  case "$h" in ""|+*|-*|*:*|refs/*|release/*|*..*) return 1 ;; esac
  IFS=, read -ra prot <<<"$PROTECTED"
  for b in "${prot[@]}"; do [ "$h" = "$b" ] && return 1; done
  git -C "$MAIN" check-ref-format --branch "$h" >/dev/null 2>&1
}

# ---------------------------------------------------------------- worktrees and permissions
# Keep the pool's per-worktree tool configuration out of every commit. info/exclude is shared by
# all worktrees of the clone; skip-worktree covers a repo that already tracks .cursor/cli.json.
exclude_tool_config() { # wt
  local wt="$1" ex entry
  ex="$(git -C "$wt" rev-parse --path-format=absolute --git-path info/exclude 2>/dev/null)" || return 1
  mkdir -p "$(dirname "$ex")"; touch "$ex"
  for entry in "/.cursor/cli.json" "/.grok/" "/$CONTEXT_FILE"; do
    grep -qxF "$entry" "$ex" || printf '%s\n' "$entry" >> "$ex"
  done
  if git -C "$wt" ls-files --error-unmatch .cursor/cli.json >/dev/null 2>&1; then
    git -C "$wt" update-index --skip-worktree .cursor/cli.json
  fi
}

policy() { # action provider job wt report
  python3 "$SCRIPTS/policy.py" "$1" --provider "$2" --job "$3" --adapter "$ADAPTER" --worktree "$4" --report "$5"
}
load_policy() { # provider job wt report -> ALLOW DENY
  local kind rule
  ALLOW=(); DENY=()
  while IFS=$'\t' read -r kind rule; do
    case "$kind" in allow) ALLOW+=("$rule") ;; deny) DENY+=("$rule") ;; esac
  done < <(policy rules "$@")
}

# ---------------------------------------------------------------- adapters
# build_cmd provider job wt prompt-file report -> CMD (argv), CMD_ENV (env(1) options), CMD_STDIN.
# Full binary paths always; never a bare `agent`, which is Cursor's alias.
build_cmd() {
  local p="$1" job="$2" wt="$3" prompt="$4" report="$5" model rule
  model="$(model_for "$p")"
  CMD=(); CMD_ENV=(); CMD_STDIN=/dev/null; ALLOW=(); DENY=()
  case "$p" in
    claude)
      load_policy claude "$job" "$wt" "$report"
      # The stale ANTHROPIC_API_KEY incident: never let an inherited API key pick the billing account.
      CMD_ENV=(-u ANTHROPIC_API_KEY)
      # --add-dir lets it write the report in $RUNS (Write is scoped to that one file); the
      # PreToolUse hook runs policy.py's argument check on every tool call.
      CMD=("$CLAUDE_BIN" -p --output-format json --model "$model"
        --permission-mode "${CLAUDE_PERMISSION_MODE:-default}" --add-dir "$RUNS"
        --settings "$(policy hook-settings claude "$job" "$wt" "$report")"
        --allowedTools "${ALLOW[@]}" --disallowedTools "${DENY[@]}")
      CMD_STDIN="$prompt" ;;
    cursor)
      # No --force: the per-worktree cli.json allowlist decides. Always --model: cursor-agent
      # saves the model it is given as the global default.
      CMD=("$CURSOR_AGENT_BIN" -p --trust --workspace "$wt" --output-format stream-json
        --model "$model" "$(cat "$prompt")") ;;
    grok)
      load_policy grok "$job" "$wt" "$report"
      CMD=("$GROK_BIN" --cwd "$wt" --prompt-file "$prompt" --output-format json
        --permission-mode "${GROK_PERMISSION_MODE:-dontAsk}")
      for rule in "${ALLOW[@]}"; do CMD+=(--allow "$rule"); done
      for rule in "${DENY[@]}"; do CMD+=(--deny "$rule"); done
      CMD+=(-m "$model") ;;
    agy)
      # No inner timeout and no print timeout by default: WORKER_TIMEOUT is the only clock.
      # Plan mode cannot write files, so a review's report is agy's final response.
      CMD=("$AGY_BIN" -p "$(cat "$prompt")" --output-format json --print-timeout "${AGY_PRINT_TIMEOUT:-0}")
      if [ "$job" = review ]; then CMD+=(--mode plan); else CMD+=(--dangerously-skip-permissions); fi
      [ -n "$model" ] && CMD+=(--model "$model") ;;
    codex)
      CMD=("$CODEX_BIN" exec --ephemeral --sandbox "${CODEX_SANDBOX_MODE:-workspace-write}"
        --model "$model" --cd "$wt" -)
      CMD_STDIN="$prompt" ;;
  esac
}

# ---------------------------------------------------------------- verification
# The same gates as pr-loop.sh's verify(), read from Gitea after the controller has published,
# with one distinction the pool needs: a missing marker is reported as fail-nomarker, because a
# fast run that left no marker is a limit, not a defect.
verify() { # job pr base-sha headref [pushed-sha] -> ok | clean | fail-nomarker:<reason> | fail:<reason>
  local job="$1" pr="$2" sha="$3" headref="$4" pushed="${5:-}"
  if [ "$job" = "review" ]; then
    local m; m="$(PR_LOOP_REPO="$REPO" python3 "$MARKER" latest "$pr" 2>/dev/null || true)"
    if [ "${m%% *}" != "$sha" ]; then echo "fail-nomarker:no review comment carrying the marker for $sha was found"; return; fi
    if [ "${m##* }" = "0" ]; then echo clean; else echo ok; fi
    return
  fi
  local newsha delay; newsha="$(python3 "$ADAPTER" head --repo "$REPO" --pr "$pr" 2>/dev/null)"
  if [ -n "$pushed" ] && [ "$newsha" != "$pushed" ]; then
    # Gitea updates a PR's head asynchronously after a push.
    for delay in $HEAD_SETTLE; do
      sleep "$delay"
      newsha="$(python3 "$ADAPTER" head --repo "$REPO" --pr "$pr" 2>/dev/null)"
      [ "$newsha" = "$pushed" ] && break
    done
    if [ "$newsha" != "$pushed" ] \
       && [ "$(git -C "$MAIN" ls-remote origin "refs/heads/$headref" 2>/dev/null | cut -f1)" = "$pushed" ]; then
      newsha="$pushed"
    fi
  fi
  if [ -z "$newsha" ]; then echo "fail:could not read the PR head after the run"; return; fi
  git -C "$MAIN" fetch origin --quiet "refs/heads/$headref" 2>/dev/null
  local rm; rm="$(PR_LOOP_REPO="$REPO" python3 "$MARKER" resolve "$pr" 2>/dev/null || true)"
  if [ -z "$rm" ]; then echo "fail-nomarker:the resolver left no disposition marker, so what it did to each finding is unknown"; return; fi
  local review; review="$(PR_LOOP_REPO="$REPO" python3 "$MARKER" latest "$pr" 2>/dev/null || true)"
  local ff=yes
  if [ "$newsha" != "$sha" ] && ! git -C "$MAIN" merge-base --is-ancestor "$sha" "$newsha" 2>/dev/null; then ff=no; fi
  # The same check the doctor applies before it calls a PR settled (scripts/marker.py).
  python3 "$SCRIPTS/marker.py" check-resolve --review "$review" --resolve "$rm" --base "$sha" --head "$newsha" \
    --fast-forward "$ff" 2>/dev/null || echo "fail:the resolver's disposition marker could not be checked"
}

# derive_job pr sha headref -> DJ (review|resolve|settled), DBASE (the head verify measures from),
# DRHEAD, DNFIND, DWHY. settled means the work is already verified: a clean review of this head,
# or a resolve that answered the latest review and verifies at this head. It needs no provider.
derive_job() {
  local pr="$1" sha="$2" m mhead mcount r r_head r_reviewed
  DJ=review; DBASE="$sha"; DRHEAD=""; DNFIND=""; DWHY=""
  m="$(PR_LOOP_REPO="$REPO" python3 "$MARKER" latest "$pr" 2>/dev/null || true)"
  mhead="${m%% *}"; mcount="${m##* }"
  if [ -n "$m" ] && [ "$mhead" = "$sha" ]; then
    if [ "${mcount:-0}" -gt 0 ]; then DJ=resolve; DRHEAD="$sha"; DNFIND="$mcount"
    else DJ=settled; DWHY="the review of $sha is already posted and clean"; fi
    return
  fi
  r="$(PR_LOOP_REPO="$REPO" python3 "$MARKER" resolve "$pr" 2>/dev/null || true)"
  read -r r_head r_reviewed _ <<<"$r"
  if [ -n "$r" ] && [ -n "$m" ] && [ "$r_head" = "$sha" ] && [ "$r_reviewed" = "$mhead" ] \
     && [ "$(verify resolve "$pr" "$mhead" "$3")" = ok ]; then
    DJ=settled; DBASE="$mhead"; DRHEAD="$mhead"; DNFIND="$mcount"
    DWHY="the resolve of $mhead is already verified at $sha"
  fi
}

# ---------------------------------------------------------------- claims and guarded writes
JOB_PR=""; ATTEMPT=""; JOB_KIND=""; JOB_WT=""; JOB_LOST=0; JOB_LOSTFILE=""
REVIEW_HEAD=""; FINDINGS=""; WORKER_PG=""; WATCH_PID=""; TICK_ID="$(date +%s)-$$"
claim() { local action="$1"; shift; python3 "$SCRIPTS/claim-record.py" "$action" --repo "$REPO" --pr "$JOB_PR" "$@"; }
jlog() { log "$REPO#$JOB_PR${ATTEMPT:+ attempt=${ATTEMPT:0:8}} $*"; }
wt_for() { printf '%s' "$WT_ROOT/pool-$JOB_PR-$TICK_ID-$1"; }

# Run one write under the claim guard. Exit 4 means this attempt was superseded.
guarded() { # what cmd...
  local what="$1" err rc; shift
  err="$(claim guard --attempt "$ATTEMPT" -- "$@" 2>&1 >/dev/null)"
  rc=$?
  if [ "$rc" -eq 4 ]; then
    JOB_LOST=1; jlog "claim superseded; $what refused: ${err//$'\n'/ }"
  elif [ "$rc" -ne 0 ]; then
    jlog "warning: $what failed: ${err//$'\n'/ }"
  fi
  return "$rc"
}
comment_file() { # body-file
  guarded "comment" python3 "$ADAPTER" comment --repo "$REPO" --pr "$JOB_PR" --body-file "$1"
}
release_to() { # label
  local err rc
  err="$(claim release --attempt "$ATTEMPT" -- python3 "$ADAPTER" label --repo "$REPO" --pr "$JOB_PR" \
    --remove "$CLAIMED" --add "$1" 2>&1 >/dev/null)"
  rc=$?
  if [ "$rc" -eq 4 ]; then JOB_LOST=1; jlog "claim superseded; release refused: ${err//$'\n'/ }"
  elif [ "$rc" -ne 0 ]; then jlog "warning: release to $1 failed; the record stays for reconciliation: ${err//$'\n'/ }"; fi
  [ "$rc" -eq 0 ] && rm -f "$(published_mark "$ATTEMPT")"
  return "$rc"
}
published_mark() { printf '%s/%s__%s.%s' "$PUBLISHED" "$(slug "$REPO")" "$JOB_PR" "$1"; }
# The job's outcome is already on Gitea; a failed release must not cost anyone a cooldown strike.
mark_published() { : > "$(published_mark "$ATTEMPT")"; }

# ---------------------------------------------------------------- worker process group and watcher
spawn_worker() { # out err
  # setsid makes the worker a session and process-group leader, so $! is also its group id and
  # one kill reaches everything it started. The pushurl override makes any worker push fail
  # whatever its CLI permits.
  ( cd "$JOB_WT" && exec setsid timeout -k 30 "$WORKER_TIMEOUT" env "${CMD_ENV[@]}" GIT_CONFIG_COUNT=1 \
      GIT_CONFIG_KEY_0=remote.origin.pushurl GIT_CONFIG_VALUE_0="$NOPUSH_URL" "${CMD[@]}" \
      <"$CMD_STDIN" >"$1" 2>"$2" ) &
  WORKER_PG=$!
}
kill_worker_group() {
  [ -n "$WORKER_PG" ] || return 0
  kill -TERM -- "-$WORKER_PG" 2>/dev/null && { sleep 1; kill -KILL -- "-$WORKER_PG" 2>/dev/null; }
  WORKER_PG=""
}

# A read-only watcher, not a renewer: it re-reads the claim and kills the worker's whole group
# the moment this attempt is no longer current.
watch_start() {
  local parent=$$ pg="$WORKER_PG" attempt="$ATTEMPT" pr="$JOB_PR"
  JOB_LOSTFILE="$RUNS/lost-$pr-$attempt"; rm -f "$JOB_LOSTFILE"
  (
    trap - EXIT INT
    sp=""
    trap '[ -n "$sp" ] && kill "$sp" 2>/dev/null; exit 0' TERM
    while :; do
      sleep "$WATCH_SECS" & sp=$!
      wait "$sp"
      kill -0 "$parent" 2>/dev/null || exit 0
      kill -0 "$pg" 2>/dev/null || exit 0
      if ! python3 "$SCRIPTS/claim-record.py" check --repo "$REPO" --pr "$pr" --attempt "$attempt" 2>>"$LOG"; then
        : > "$JOB_LOSTFILE"
        kill -TERM -- "-$pg" 2>/dev/null; sleep 2; kill -KILL -- "-$pg" 2>/dev/null
        exit 0
      fi
    done
  ) &
  WATCH_PID=$!
}
watch_stop() {
  [ -n "$WATCH_PID" ] && { kill "$WATCH_PID" 2>/dev/null; wait "$WATCH_PID" 2>/dev/null; }
  WATCH_PID=""
}
still_held() {
  [ ! -f "$JOB_LOSTFILE" ] && claim check --attempt "$ATTEMPT" 2>/dev/null
}

# worker_head wt -> the worker's HEAD commit, read through the main clone. The controller never
# runs git inside a worker's worktree after the worker started: its .git pointer, config and
# hooks are the worker's to rewrite.
worker_head() {
  local common want d
  common="$(git -C "$MAIN" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  want="$(realpath -m "$1")/.git"
  for d in "$common"/worktrees/*/; do
    [ "$(realpath -m "$(cat "$d/gitdir" 2>/dev/null)")" = "$want" ] || continue
    git -C "$MAIN" rev-parse --verify -q "worktrees/$(basename "$d")/HEAD^{commit}"
    return
  done
  return 1
}

remove_worktree() { # wt
  [ -n "$1" ] && [ -d "$1" ] || return 0
  git -C "$MAIN" worktree remove --force "$1" >/dev/null 2>&1 || jlog "worktree $1 kept (busy); inspect and remove by hand"
}

end_job() {
  kill_worker_group; watch_stop
  remove_worktree "$JOB_WT"
  gate_cleanup
  rm -f "$JOB_LOSTFILE"
  JOB_PR=""; ATTEMPT=""; JOB_KIND=""; JOB_WT=""; JOB_LOST=0; JOB_LOSTFILE=""
}

finish_job() { # done|ready|fail reason
  local outcome="$1" reason="$2" target bf
  case "$outcome" in done) target="$DONE" ;; ready) target="$READY" ;; fail) target="$HUMAN" ;; esac
  if [ "$outcome" = fail ] && [ "$JOB_LOST" -eq 0 ]; then
    bf="$(mktemp)"
    printf 'Automated %s pool stopped on this PR: %s. A human needs to look; the pool log on the review host has the detail.\n' \
      "$JOB_KIND" "$reason" > "$bf"
    comment_file "$bf"; rm -f "$bf"
  fi
  [ "$JOB_LOST" -eq 0 ] && release_to "$target"
  if [ "$JOB_LOST" -eq 0 ]; then jlog "$outcome -> $target ($reason)"; else jlog "superseded; touched nothing more ($reason)"; fi
  end_job
}

on_exit() {
  local rc=$?
  if [ -n "$ATTEMPT" ]; then
    kill_worker_group
    [ "$JOB_LOST" -eq 0 ] && finish_job ready "the pool tick exited unexpectedly (exit $rc) while holding the job"
  fi
  watch_stop
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------- controller-run gates
MAIN_GITDIR=""; MAIN_CONFIG_SUM=""; GATE_DIR=""; GATE_RECEIPT=""

# Every controller git call on the gate path. Nothing inherited reaches git: no GIT_* from the
# tick's env, no global or system config (aliases, filters, textconv, insteadOf), no hooks, no
# replace refs or grafts. MAIN's own config is the only one read; it is controller-owned and its
# checksum is re-checked before the checkout and before the push.
gate_git() { # [GIT_INDEX_FILE=path] git-args...
  local idx=()
  case "${1:-}" in GIT_INDEX_FILE=*) idx=("$1"); shift ;; esac
  env -i PATH=/usr/bin:/bin HOME="$STATE/empty-home" LANG=C.UTF-8 \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_DIR="$MAIN_GITDIR" \
    GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null GIT_TERMINAL_PROMPT=0 "${idx[@]}" \
    git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.untrackedCache=false \
      -c filter.lfs.smudge= -c filter.lfs.process= -c filter.lfs.required=false \
      -c core.symlinks=true -c core.autocrlf=false "$@"
}

gate_config_intact() {
  [ -n "$MAIN_CONFIG_SUM" ] && [ "$(sha256sum < "$MAIN_GITDIR/config" 2>/dev/null)" = "$MAIN_CONFIG_SUM" ]
}

# gate_checkout commit -> GATE_DIR: the commit's tracked content only, through a private index,
# in a fresh directory that is not a git worktree. No .git, no untracked or ignored files from
# the worker's worktree, no export-ignore/export-subst (that would be git archive).
gate_checkout() {
  mkdir -p "$STATE/gate-work" "$STATE/empty-home"
  GATE_DIR="$(mktemp -d "$STATE/gate-work/$(slug "$REPO")-$JOB_PR-XXXXXX")" || return 1
  gate_git "GIT_INDEX_FILE=$GATE_DIR.index" read-tree "$1" || return 1
  ( cd "$GATE_DIR" && gate_git "GIT_INDEX_FILE=$GATE_DIR.index" --work-tree="$GATE_DIR" checkout-index -a -f ) || return 1
  rm -f "$GATE_DIR.index"
}

gate_cleanup() {
  [ -n "$GATE_DIR" ] || return 0
  chmod -R u+w "$GATE_DIR" 2>/dev/null
  rm -rf "$GATE_DIR" "$GATE_DIR.index"
  GATE_DIR=""
}

claim_secs_left() {
  claim show 2>/dev/null | python3 -c '
import datetime, json, os, sys, time
d = json.load(sys.stdin).get("expected_deadline_at")
now = float(os.environ.get("AGENT_POOL_NOW") or time.time())
print(int(datetime.datetime.strptime(d, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp() - now) if d else 0)'
}

# gate_receipt provider sha newhead base-sha manifest-json result reason [run-json] -> GATE_RECEIPT
gate_receipt() {
  local src blob
  read -r src blob < <(python3 -c 'import json,sys
try: d = json.load(open(sys.argv[1]))
except (OSError, ValueError): d = {}
print(d.get("source") or "none", d.get("blob") or "-")' "$5")
  [ "$blob" = - ] && blob=""
  GATE_RECEIPT="$(python3 "$SCRIPTS/gates.py" receipt --state "$STATE" --repo "$REPO" --pr "$JOB_PR" \
    --attempt "$ATTEMPT" --provider "$1" --base-sha "$4" --pr-head "$2" --head "$3" --source "$src" \
    --blob "$blob" --result "$6" --reason "$7" ${8:+--run "$8"} 2>>"$LOG")"
}

# run_gates provider sha newhead base -> 0 with GATE_RECEIPT naming a passing receipt, else 1
# with PUB set: fail:<why> (a red gate, protected paths, no manifest), gateinfra:<why> or lost.
# The worker's process group is already dead; nothing here reads the worker's worktree.
run_gates() {
  local p="$1" sha="$2" newhead="$3" base="$4" tag base_sha manifest raw hits names budget left run res why
  tag="$JOB_PR-${ATTEMPT:0:8}"; manifest="$RUNS/gates-manifest-$tag.json"; raw="$RUNS/gates-diff-$tag"
  run="$RUNS/gates-run-$tag.json"; GATE_RECEIPT=""
  gate_config_intact || { PUB="gateinfra:the main clone's git config changed during the job; refusing to gate or push"; return 1; }
  [ "$(gate_git rev-parse --verify -q "$newhead^{commit}")" = "$newhead" ] \
    || { PUB="gateinfra:the worker's head $newhead is not a commit in the main clone"; return 1; }
  gate_git merge-base --is-ancestor "$sha" "$newhead" 2>/dev/null \
    || { PUB="fail:the worker's commits at $newhead are not a fast-forward of $sha"; return 1; }
  base_sha="$(gate_git rev-parse --verify -q "refs/remotes/origin/$base^{commit}")" \
    || { PUB="gateinfra:cannot resolve origin/$base in the main clone"; return 1; }
  if ! python3 "$SCRIPTS/gates.py" load --main "$MAIN" --base-sha "$base_sha" --repo "$REPO" > "$manifest" 2>"$raw.err"; then
    why="the gate manifest for $REPO at $base_sha is unreadable or invalid: $(head -c 300 "$raw.err" | tr '\n' ' ')"
    gate_receipt "$p" "$sha" "$newhead" "$base_sha" "$manifest" infra "$why"
    PUB="gateinfra:$why"; return 1
  fi
  gate_git diff-tree -r -z --no-renames --raw "$sha" "$newhead" > "$raw" \
    && python3 "$SCRIPTS/gates.py" changes --raw "$raw" --changed-out "$raw.changed" --gitlinks-out "$raw.gitlinks" \
    || { PUB="gateinfra:could not list the paths the worker changed"; return 1; }
  hits="$(python3 "$SCRIPTS/gates.py" protected --manifest "$manifest" --changed "$raw.changed" --gitlinks "$raw.gitlinks")" \
    || { PUB="gateinfra:could not check the worker's changes against the protected paths"; return 1; }
  if [ "$hits" != none ]; then
    why="the worker's commits change gate-defining files ($(printf '%s\n' "$hits" | head -5 | tr '\n' ' ' | sed 's/ $//')); a human must review them"
    gate_receipt "$p" "$sha" "$newhead" "$base_sha" "$manifest" protected "$why"
    PUB="fail:$why"; return 1
  fi
  if grep -q '"source": "none"' "$manifest"; then
    if python3 "$SCRIPTS/gates.py" docs-only --changed "$raw.changed"; then
      gate_receipt "$p" "$sha" "$newhead" "$base_sha" "$manifest" none-needed "no gate manifest, and only documentation changed"
      [ -n "$GATE_RECEIPT" ] || { PUB="gateinfra:could not write the gate receipt"; return 1; }
      jlog "gates: none needed (no manifest, documentation only) at $newhead"; return 0
    fi
    why="$REPO has no gate manifest (.agent-pool/gates.toml on $base or a controller override), so the worker's code changes cannot be gated"
    gate_receipt "$p" "$sha" "$newhead" "$base_sha" "$manifest" no-manifest "$why"
    PUB="fail:$why"; return 1
  fi
  names="$(python3 "$SCRIPTS/gates.py" select --manifest "$manifest" --changed "$raw.changed")" \
    || { PUB="gateinfra:could not select the gates for the worker's changes"; return 1; }
  if [ "$names" = none ]; then
    gate_receipt "$p" "$sha" "$newhead" "$base_sha" "$manifest" none-needed "no gate applies to the changed paths"
    [ -n "$GATE_RECEIPT" ] || { PUB="gateinfra:could not write the gate receipt"; return 1; }
    jlog "gates: none apply to the changed paths at $newhead"; return 0
  fi
  left="$(claim_secs_left)"; budget=$(( ${left:-0} - 60 ))
  [ "$budget" -gt "$GATE_BUDGET" ] && budget="$GATE_BUDGET"
  gate_config_intact || { PUB="gateinfra:the main clone's git config changed during the job; refusing to gate or push"; return 1; }
  gate_checkout "$newhead" || { gate_cleanup; PUB="gateinfra:could not check out $newhead for the gates"; return 1; }
  printf '%s\n' "$names" > "$raw.select"
  jlog "gates: running $(printf '%s' "$names" | tr '\n' ' ')at $newhead (budget ${budget}s)"
  # Its own process group, watched like a worker: a superseded claim kills the gate run too.
  setsid python3 "$SCRIPTS/gates.py" run --manifest "$manifest" --gate-dir "$GATE_DIR" --select "$raw.select" \
    --runs "$RUNS" --tag "$tag" --budget "$budget" --lock "$STATE/gates.lock" > "$run" 2>>"$LOG" &
  WORKER_PG=$!
  watch_start
  wait "$WORKER_PG"
  watch_stop; kill_worker_group
  gate_cleanup
  if ! still_held; then PUB=lost; return 1; fi
  IFS=$'\t' read -r res why < <(python3 -c 'import json,sys
try: d = json.load(open(sys.argv[1]))
except (OSError, ValueError): d = {"result": "infra", "reason": "the gate runner left no result"}
print(d.get("result") or "infra", (d.get("reason") or "-").replace("\t", " ").replace("\n", " "), sep="\t")' "$run")
  [ "$why" = - ] && why=""
  gate_receipt "$p" "$sha" "$newhead" "$base_sha" "$manifest" "$res" "$why" "$run"
  [ -n "$GATE_RECEIPT" ] || { PUB="gateinfra:could not write the gate receipt for $newhead (one may already exist for this attempt)"; return 1; }
  jlog "gates: $res at $newhead${why:+ ($why)}"
  case "$res" in
    pass) return 0 ;;
    gate-fail|gate-timeout|gate-resource)
      PUB="fail:the controller's gates are red at $newhead: $why; nothing was pushed (gate logs are on the pool host)"; return 1 ;;
    *) PUB="gateinfra:${why:-the gate run failed}"; return 1 ;;
  esac
}

# ---------------------------------------------------------------- controller-side publication
# publish provider sha headref report result base -> PUB: published | nomarker:<why> |
# requeue:<why> | fail:<why> | gateinfra:<why> | lost. The only path by which a worker's work
# reaches Gitea.
publish() {
  local p="$1" sha="$2" headref="$3" report="$4" result="$5" base="$6" chk alt head fixed newhead remote rc tool scan
  local args=(--marker-module "$MARKER")
  PUSHED=""
  if [ "$JOB_KIND" = review ]; then args+=(--sha "$sha")
  else args+=(--review-head "$REVIEW_HEAD" --findings "${FINDINGS:-0}"); fi
  chk="$(python3 "$SCRIPTS/report.py" "$JOB_KIND" "${args[@]}" --file "$report")"
  if [ "${chk%%$'\t'*}" != ok ] && [ -s "$result" ]; then
    alt="$(python3 "$SCRIPTS/report.py" "$JOB_KIND" "${args[@]}" --file "$result")"
    [ "${alt%%$'\t'*}" = ok ] && { report="$result"; chk="$alt"; }
  fi
  case "${chk%%$'\t'*}" in
    ok) ;;
    invalid) PUB="fail:${chk#*$'\t'}"; return ;;
    *) PUB="nomarker:${chk#*$'\t'}"; return ;;
  esac
  IFS=$'\t' read -r _ head fixed <<<"$chk"
  if [ "$JOB_KIND" = resolve ]; then
    newhead="$(worker_head "$JOB_WT")" || { PUB="fail:could not read the worker's HEAD through the main clone"; return; }
    if [ "$head" != "$newhead" ]; then PUB="fail:the resolve marker names head $head but the worker's worktree is at $newhead"; return; fi
    if [ "$newhead" != "$sha" ] && [ "${fixed:-0}" -eq 0 ]; then
      PUB="fail:the worker committed on top of $sha but its marker claims no fixes"; return
    fi
    if [ "$newhead" != "$sha" ]; then
      headref_safe "$headref" || { PUB="fail:refusing to push to '$headref'"; return; }
      git -C "$MAIN" merge-base --is-ancestor "$sha" "$newhead" 2>/dev/null \
        || { PUB="fail:the worker's commits at $newhead are not a fast-forward of $sha"; return; }
      tool="$(git -C "$MAIN" diff --name-only "$sha" "$newhead" 2>/dev/null \
        | grep -E "(^|/)\.(cursor|grok|claude)/|(^|/)${CONTEXT_FILE//./\\.}\$" | head -3 | tr '\n' ' ')"
      [ -z "$tool" ] || { PUB="fail:the worker's commits touch agent tool configuration (${tool% }); refusing to push"; return; }
      # Commit messages and added lines go public with the push; nothing secret may ride along.
      scan="$RUNS/push-scan-$JOB_PR-${ATTEMPT:0:8}.txt"
      { git -C "$MAIN" log --format=%B "$sha..$newhead"; git -C "$MAIN" diff "$sha" "$newhead" | grep '^+' | grep -v '^+++ '; } \
        > "$scan" 2>/dev/null
      if ! python3 "$SCRIPTS/report.py" scan --file "$scan" >/dev/null; then
        rm -f "$scan"
        PUB="fail:the worker's commits contain a credential or token-shaped string; refusing to push"; return
      fi
      rm -f "$scan"
      run_gates "$p" "$sha" "$newhead" "$base" || return
      remote="$(git -C "$MAIN" ls-remote origin "refs/heads/$headref" 2>/dev/null | cut -f1)"
      [ "$remote" = "$sha" ] || { PUB="requeue:origin/$headref is at ${remote:-nothing}, not $sha; the branch moved during the run"; return; }
      gate_config_intact || { PUB="gateinfra:the main clone's git config changed before the push; refusing to push"; return; }
      python3 "$SCRIPTS/gates.py" check-receipt --state "$STATE" --repo "$REPO" --pr "$JOB_PR" --attempt "$ATTEMPT" \
        --head "$newhead" 2>>"$LOG" || { PUB="gateinfra:no passing gate receipt for this attempt at $newhead; refusing to push"; return; }
      python3 "$SCRIPTS/gates.py" annotate --report "$report" --receipt "$GATE_RECEIPT" --out "$report.gated" \
        || { PUB="gateinfra:could not add the gate section to the report"; return; }
      report="$report.gated"
      # No hooks and no force: the server refuses anything that is not a fast-forward.
      guarded "push" git -C "$MAIN" -c core.hooksPath=/dev/null push --quiet --no-verify origin "$newhead:refs/heads/$headref"
      rc=$?
      case "$rc" in 0) ;; 4) PUB=lost; return ;; *) PUB="requeue:the push of $newhead to $headref failed"; return ;; esac
      PUSHED="$newhead"
      jlog "pushed $sha..$newhead to $headref for $p"
    fi
  fi
  comment_file "$report"; rc=$?
  case "$rc" in 0) PUB=published ;; 4) PUB=lost ;; *) PUB="requeue:posting the $JOB_KIND report failed" ;; esac
  # If the release after this fails, the claim goes stale although the provider did its job.
  [ "$PUB" = published ] && mark_published
}

# ---------------------------------------------------------------- one provider attempt
prepare_worktree() { # sha headref -> JOB_WT
  JOB_WT="$(wt_for "$CURRENT_PROVIDER")"
  git -C "$MAIN" fetch origin --quiet "refs/heads/$2" 2>/dev/null || { jlog "fetch $2 failed"; return 1; }
  [ -d "$JOB_WT" ] && git -C "$MAIN" worktree remove --force "$JOB_WT" >/dev/null 2>&1
  git -C "$MAIN" worktree add --detach "$JOB_WT" "$1" >/dev/null 2>&1 || { jlog "worktree add failed"; return 1; }
  exclude_tool_config "$JOB_WT"
}

# write_context sha base -> $JOB_WT/$CONTEXT_FILE: what a worker that cannot run commands (agy in
# plan mode) needs. A file, not an argument: one argument over 128 KiB fails exec with E2BIG.
write_context() {
  local f="$JOB_WT/$CONTEXT_FILE"
  {
    printf '# Context for PR #%s at %s (base %s), gathered by the pool controller\n\n' "$JOB_PR" "$1" "$2"
    printf '## Commits (git log origin/%s..%s)\n\n```\n' "$2" "$1"
    git -C "$MAIN" log --format='%h %s' "origin/$2..$1" 2>/dev/null
    printf '```\n\n## Diff (git diff origin/%s...%s)\n\n```diff\n' "$2" "$1"
    git -C "$MAIN" diff "origin/$2...$1" 2>/dev/null
    printf '```\n\n## PR comments (JSON)\n\n```json\n'
    python3 "$ADAPTER" comments --repo "$REPO" --pr "$JOB_PR" 2>/dev/null || echo '[] (could not read the comments)'
    printf '```\n'
  } > "$f"
}

render_prompt() { # provider sha headref base report -> prompt file path
  local out="$RUNS/prompt-$JOB_PR-${ATTEMPT:0:8}-$1.txt"
  python3 "$SCRIPTS/render-prompt.py" "$(prompt_for "$1" "$JOB_KIND")" "$out" "PR=$JOB_PR" "HEADREF=$3" \
    "SHA=$2" "BASE=$4" "REPO=$REPO" "ADAPTER=$ADAPTER" "COMMON=$COMMON" "REPORT=$5" \
    "SENTINEL=POOL_RUN_DONE" "REVIEW_HEAD=$REVIEW_HEAD" "FINDINGS=$FINDINGS" "CONTEXT=$JOB_WT/$CONTEXT_FILE"
  printf '%s' "$out"
}

# attempt provider sha headref base -> VERDICT (done findings fail setup limit timeout requeue lost), DETAIL.
# Runs in the calling shell: it sets JOB_WT and may record setup faults.
attempt() {
  local p="$1" sha="$2" headref="$3" base="$4" tag prompt report result out err rc t0 elapsed cls session v
  VERDICT=""; DETAIL=""; CURRENT_PROVIDER="$p"
  prepare_worktree "$sha" "$headref" || { VERDICT=setup; DETAIL="could not prepare a worktree at $sha"; return; }
  tag="$JOB_PR-${ATTEMPT:0:8}-$p"
  report="$RUNS/report-$tag.md"; result="$RUNS/result-$tag.txt"; rm -f "$report" "$result"
  out="$RUNS/out-$tag.json"; err="$RUNS/err-$tag.txt"
  write_context "$sha" "$base"
  prompt="$(render_prompt "$p" "$sha" "$headref" "$base" "$report")"
  if [ "$p" = cursor ]; then
    mkdir -p "$JOB_WT/.cursor"
    policy cursor-json cursor "$JOB_KIND" "$JOB_WT" "$report" > "$JOB_WT/.cursor/cli.json"
  fi
  build_cmd "$p" "$JOB_KIND" "$JOB_WT" "$prompt" "$report"
  jlog "spawning $p for $JOB_KIND (model $(model_for "$p" | sed 's/^$/provider default/')) in $JOB_WT at $sha"
  t0="$(date +%s)"
  spawn_worker "$out" "$err"
  watch_start
  wait "$WORKER_PG"; rc=$?
  elapsed=$(( $(date +%s) - t0 ))
  watch_stop; kill_worker_group
  if ! still_held; then VERDICT=lost; DETAIL="$p ran ${elapsed}s but its attempt was superseded"; return; fi
  cls="$(python3 "$SCRIPTS/classify.py" --provider "$p" --exit "$rc" --stdout "$out" --stderr "$err" --result-out "$result")"
  session="${cls##*$'\t'}"; cls="${cls%$'\t'*}"
  publish "$p" "$sha" "$headref" "$report" "$result" "$base"
  case "$PUB" in
    lost)       VERDICT=lost; DETAIL="$p's attempt was superseded before its work was published"; return ;;
    requeue:*)  VERDICT=requeue; DETAIL="${PUB#*:}"; return ;;
    # Before the provider's own verdict: this is the controller's fault, not the provider's.
    gateinfra:*)
      setup_fault gates "${PUB#*:}"
      VERDICT=requeue; DETAIL="the controller's gate run could not complete (${PUB#*:})"; return ;;
    published)  v="$(verify "$JOB_KIND" "$JOB_PR" "$sha" "$headref" "$PUSHED")" ;;
    nomarker:*) v="fail-nomarker:${PUB#*:}" ;;
    *)          v="$PUB" ;;
  esac
  jlog "$p exited $rc after ${elapsed}s; provider says ${cls%%$'\t'*}; verification says ${v%%:*}${session:+; session $session}"
  case "$v" in
    ok|clean)
      # The verified outcome stands either way; the provider's own complaint is still recorded.
      case "$cls" in
        setup*) setup_fault "$p" "${cls#*$'\t'} (the run still verified, so its outcome stands)" ;;
        limit*) python3 "$SCRIPTS/cooldown.py" record --provider "$p" --reason "${cls#*$'\t'}" >/dev/null ;;
        *)      python3 "$SCRIPTS/cooldown.py" clear --provider "$p" ;;
      esac
      if [ "$JOB_KIND" = review ] && [ "$v" = ok ]; then VERDICT=findings; else VERDICT=done; fi
      DETAIL="$p verified"; return ;;
  esac
  case "$cls" in
    setup*)   VERDICT=setup; DETAIL="${cls#*$'\t'}"; return ;;
    limit*)   VERDICT=limit; DETAIL="${cls#*$'\t'}"; return ;;
    timeout*) VERDICT=timeout; DETAIL="${cls#*$'\t'} after ${elapsed}s with no verified result"; return ;;
  esac
  if [ "${v%%:*}" = "fail-nomarker" ] && [ "$elapsed" -lt "$FAST_FAIL_SECS" ]; then
    VERDICT=limit; DETAIL="$p ended after ${elapsed}s (under ${FAST_FAIL_SECS}s) with no marker: ${cls#*$'\t'}"
    return
  fi
  VERDICT=fail; DETAIL="${v#*:} ($p, ${elapsed}s)"
}

# ---------------------------------------------------------------- one job
run_job() { # pr headref sha base job verify-base review-head findings remove-labels providers...
  local pr="$1" headref="$2" sha="$3" base="$4" job="$5" vbase="$6" rhead="$7" nfind="$8" remove="$9"
  shift 9
  local p id rc before tried=() first=1 holds="$EXTRA_HOLD"
  JOB_PR="$pr"; JOB_KIND="$job"; REVIEW_HEAD="$rhead"; FINDINGS="$nfind"; JOB_LOST=0; JOB_WT=""
  # Reclaiming a dead hold removes the hold label in the same flip, so it cannot also refuse it.
  [ "$remove" != "$READY" ] && holds=""
  id="$(claim claim --worker "$WORKER_ID" --provider "$1" --job "$job" --branch "$headref" --worktree "$(wt_for "$1")" \
    --adapter "$ADAPTER" --require-label "$READY" --expect-head "$sha" --hold-labels "$holds" --bot "$BOT" \
    -- python3 "$ADAPTER" label --repo "$REPO" --pr "$pr" --remove "$remove" --add "$CLAIMED" 2>>"$LOG")"
  rc=$?
  case "$rc" in
    0) ATTEMPT="$id" ;;
    3) log "$REPO#$pr: already claimed elsewhere; skipping"; JOB_PR=""; return 0 ;;
    6) log "$REPO#$pr: the PR changed since it was listed; not claimed (see $LOG)"; JOB_PR=""; return 0 ;;
    *) log "$REPO#$pr: claim failed (exit $rc); leaving the PR for a later tick"; JOB_PR=""; return 0 ;;
  esac
  jlog "claimed by $WORKER_ID for $job with $1"
  # derive_job already verified it; the claim re-checked the head, so it is not verified again.
  if [ "$job" = settled ]; then mark_published; finish_job done "$SETTLED_WHY"; return 0; fi

  before="$(verify "$job" "$pr" "$vbase" "$headref")"
  case "$before" in clean|ok) mark_published ;; esac
  case "$before" in
    clean) finish_job done "the review of $sha is already posted and clean"; return 0 ;;
    ok) if [ "$job" = resolve ]; then finish_job done "the resolve of $vbase is already verified at $sha"
        else finish_job ready "the review of $sha is already posted; queued for resolve"; fi
        return 0 ;;
  esac

  for p in "$@"; do
    if [ "$first" = 0 ]; then
      id="$(claim reattempt --attempt "$ATTEMPT" --provider "$p" --worktree "$(wt_for "$p")" 2>>"$LOG")" \
        || { JOB_LOST=1; jlog "superseded before falling back to $p; touching nothing"; end_job; return 0; }
      ATTEMPT="$id"; jlog "falling back to $p"
    fi
    first=0
    attempt "$p" "$sha" "$headref" "$base"
    tried+=("$p=$VERDICT")
    case "$VERDICT" in
      done)     finish_job done "$DETAIL"; return 0 ;;
      findings) finish_job ready "$DETAIL; findings queued for resolve"; return 0 ;;
      lost)     JOB_LOST=1; jlog "$DETAIL; touching nothing on Gitea"; end_job; return 0 ;;
      fail)     finish_job fail "$DETAIL"; return 0 ;;
      requeue)  finish_job ready "$DETAIL; back in the queue, not a needs-human"; return 0 ;;
      setup)    setup_fault "$p" "$DETAIL" ;;
      limit|timeout)
        local cd
        if [ "$VERDICT" = limit ]; then
          cd="$(python3 "$SCRIPTS/cooldown.py" record --provider "$p" --reason "$DETAIL")"
          jlog "LIMIT [$p]: $DETAIL; cooling down $(( ${cd#*$'\t'} / 60 ))m"
        else
          # A hung provider would otherwise be picked first again and cost a full WORKER_TIMEOUT.
          cd="$(python3 "$SCRIPTS/cooldown.py" record --provider "$p" --reason "$DETAIL" --seconds "$TIMEOUT_COOLDOWN")"
          jlog "TIMEOUT [$p]: $DETAIL; pausing it $(( ${cd#*$'\t'} / 60 ))m, no strike"
        fi
        if [ "$(python3 "$ADAPTER" head --repo "$REPO" --pr "$pr" 2>/dev/null)" != "$sha" ]; then
          finish_job ready "the head moved during the run; not handing a stale job to another provider"
          return 0
        fi ;;
    esac
    remove_worktree "$JOB_WT"; JOB_WT=""
  done
  finish_job ready "no provider completed the job (${tried[*]:-none eligible}); back in the queue"
}

# ---------------------------------------------------------------- the tick
[ -n "$COMMON" ] && [ -d "$COMMON" ] || die "cannot find skills/pr-loops-common (set AGENT_POOL_COMMON)"
[ -f "$ADAPTER" ] || die "missing Gitea adapter: $ADAPTER"
[ -f "$MARKER" ] || die "missing marker reader: $MARKER"
[ -n "$MAIN" ] && [ -e "$MAIN/.git" ] || die "no checkout for $REPO: set AGENT_POOL_MAIN to its clone (got '$MAIN')"
[ "$WORKER_TIMEOUT" -lt "$DEADLINE_SECS" ] \
  || die "WORKER_TIMEOUT ($WORKER_TIMEOUT) must be shorter than AGENT_POOL_DEADLINE_SECS ($DEADLINE_SECS)"
if [ "$ABILITIES_SET" = 1 ]; then
  IFS=, read -ra ability_list <<<"$ABILITIES"
  for ability in "${ability_list[@]}"; do
    case "$ability" in plan|review|prototype|test-author|resolve) ;;
      *) die "unknown ability '$ability' in AGENT_POOL_ABILITIES (plan, review, prototype, test-author, resolve)" ;;
    esac
  done
fi
WT_ROOT="${AGENT_POOL_WORKTREES:-$(dirname "$MAIN")/.pool-worktrees}"
mkdir -p "$WT_ROOT"

exec 9>"$STATE/pool-$(slug "$WORKER_ID")-$(slug "$REPO").lock"
if ! flock -n 9; then log "previous tick of $WORKER_ID for $REPO still running; exiting"; exit 0; fi

select_providers
if [ "${#PROVIDERS[@]}" -eq 0 ]; then
  log "no eligible provider in '$PROVIDER_ORDER' (cooling down or misconfigured); claiming nothing"
  [ "$SETUP_FAULTS" -gt 0 ] && exit 2
  exit 0
fi

git -C "$MAIN" fetch origin --quiet --prune 2>/dev/null || log "warning: fetch failed; continuing with what is local"
MAIN_GITDIR="$(git -C "$MAIN" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
  || die "cannot find the git directory of $MAIN"
MAIN_CONFIG_SUM="$(sha256sum < "$MAIN_GITDIR/config")" || die "cannot read $MAIN_GITDIR/config"

# Candidates carry agent:ready or agent:claimed, or have a claim record here to reconcile.
CLAIM_PRS="$(cd "$STATE/claims" 2>/dev/null && for f in "$(slug "$REPO")"__*.json; do [ -e "$f" ] && { f="${f##*__}"; printf '%s ' "${f%.json}"; }; done)"
if ! LISTING="$(python3 "$ADAPTER" list --repo "$REPO" --state open | READY="$READY" CLAIMED="$CLAIMED" CLAIM_PRS="$CLAIM_PRS" python3 -c '
import json, os, re, sys
ready, claimed = os.environ["READY"], os.environ["CLAIMED"]
recorded = set(os.environ.get("CLAIM_PRS", "").split())
raw = os.environ.get("PR_LOOP_SKIP_PATTERN", r"docblock-backfill|^chore\(#152\)")
rx = re.compile(raw) if raw else None
for pr in json.load(sys.stdin):
    labels = pr["labels"]
    if ready not in labels and claimed not in labels and str(pr["number"]) not in recorded: continue
    if pr["draft"] or pr["is_bot"]: continue
    if rx and (rx.search(pr["title"]) or rx.search(pr["head_ref"])): continue
    print("\t".join([str(pr["number"]), pr["head_ref"], pr["head_sha"], pr["base_ref"],
                     json.dumps(labels), json.dumps(pr.get("assignees", []))]))
')"; then
  die "gitea pr list failed; not treating that as an empty queue"
fi
mapfile -t CANDIDATES < <(printf '%s\n' "$LISTING" | sed '/^$/d')
[ "${#CANDIDATES[@]}" -eq 0 ] && { log "no open PR in $REPO carries $READY or $CLAIMED"; exit 0; }

# Every candidate below is in the same repo, so a cheap first pass here skips the whole tick
# early when already busy. It is NOT the real gate: MAX_JOBS can run more than one job per
# tick, each up to WORKER_TIMEOUT long, and NightCrew can start a job in that window, so a
# result cached from before the first claim would otherwise go stale before the second. Nothing
# else in agent-pool-core shares state with TheNightCrew's issue/maintenance job board; this is
# the one place the two systems' claims on the same repo could otherwise collide.
#
# nightcrew_busy asks fresh every time it is called -- here once up front, and again,
# immediately before each real claim below (Codex adversarial review, PR #13).
nightcrew_busy() {
  [ "$NIGHTCREW_CHECK" = 1 ] || return 1
  # Only exit 0 with exactly "clear" lets claiming go on; a crash, a hang, a nonzero exit or
  # any other output reads as held.
  local hold_out="" hold_rc=0
  if [[ "$NIGHTCREW_TIMEOUT" =~ ^[1-9][0-9]{0,2}$ ]]; then
    hold_out="$(timeout -k 5 "$(( NIGHTCREW_TIMEOUT * 2 + 3 ))" python3 "$NIGHTCREW_HOLD_SCRIPT" --repo "$REPO" \
      --timeout "$NIGHTCREW_TIMEOUT" 2>>"$LOG")" || hold_rc=$?
  else
    hold_rc=2
    log "AGENT_POOL_NIGHTCREW_TIMEOUT must be whole seconds from 1 to 999"
  fi
  if [ "$hold_rc" -ne 0 ] || [ "$hold_out" != "clear" ]; then
    if [ "$hold_rc" -eq 0 ] && [ "$hold_out" = "busy" ]; then
      log "$REPO: TheNightCrew reports active issue/maintenance work here"
    else
      log "$REPO: TheNightCrew issue-hold check failed (exit $hold_rc); failing closed"
    fi
    return 0
  fi
  return 1
}
[ "$NIGHTCREW_CHECK" = 1 ] && [ -n "$NIGHTCREW_LEGACY_BOT" ] && log "AGENT_POOL_NIGHTCREW_BOT is deprecated and no longer read as a bot login;" \
  "the NightCrew issue-hold endpoint check is on because it is set. Replace it with AGENT_POOL_NIGHTCREW_HOLD=1."
NIGHTCREW_HOLD=0
nightcrew_busy && { NIGHTCREW_HOLD=1; log "$REPO: no PR claimed this tick"; }

# reconcile_pr pr -> 0 to go on considering the PR (labels may have become ready), 1 to skip it.
reconcile_pr() {
  local out st aid prov info f mark
  out="$(python3 "$SCRIPTS/claim-record.py" reconcile --repo "$REPO" --pr "$1" --adapter "$ADAPTER" \
    --claimed "$CLAIMED" --needs-human "$HUMAN" 2>>"$LOG")"
  # Fields may be empty, and read would collapse adjacent tabs.
  mapfile -t f < <(printf '%s\n' "$out" | tr '\t' '\n')
  st="${f[0]:-}"; aid="${f[1]:-}"; prov="${f[2]:-}"; info="${f[3]:-}"
  case "$st" in
    live) log "$REPO#$1: claimed by a live attempt ($prov, deadline $info); skipping"; return 1 ;;
    stale)
      if python3 "$SCRIPTS/claim-record.py" requeue --repo "$REPO" --pr "$1" --attempt "$aid" --adapter "$ADAPTER" \
           --claimed "$CLAIMED" --ready "$READY" >/dev/null 2>>"$LOG"; then
        mark="$(JOB_PR="$1" published_mark "$aid")"
        if [ -e "$mark" ]; then
          rm -f "$mark"
          log "$REPO#$1: attempt ${aid:0:8} ($prov) passed its deadline $info after its work was published (only the release failed); requeued to $READY, no cooldown"
        else
          log "$REPO#$1: attempt ${aid:0:8} ($prov) passed its deadline $info; requeued to $READY"
          [ -n "$prov" ] && python3 "$SCRIPTS/cooldown.py" record --provider "$prov" \
            --reason "a claim passed its deadline with no result" >/dev/null
        fi
        RECONCILED_READY=1; return 0
      fi
      log "$REPO#$1: could not requeue the stale attempt ${aid:0:8}; skipping"; return 1 ;;
    needs-human) log "$REPO#$1: $CLAIMED with no claim record; relabelled $HUMAN"; return 1 ;;
    orphan-dropped) log "$REPO#$1: dropped the claim record of a job already released"; return 0 ;;
    free) return 0 ;;
    *) log "$REPO#$1: could not reconcile the claim ($out); skipping"; return 1 ;;
  esac
}

QUEUE=()
for row in "${CANDIDATES[@]}"; do
  IFS=$'\t' read -r pr headref sha base labels assignees <<<"$row"
  RECONCILED_READY=0
  if [[ "$labels" == *"\"$CLAIMED\""* ]] || [[ " $CLAIM_PRS" == *" $pr "* ]]; then
    if [ "$DRY_RUN" = 1 ]; then log "DRY: would reconcile the claim on $REPO#$pr"; continue; fi
    reconcile_pr "$pr" || continue
    [ "$RECONCILED_READY" = 1 ] && labels="${labels//\"$CLAIMED\"/\"$READY\"}"
  fi
  [[ "$labels" == *"\"$READY\""* ]] || continue
  if [ "$NIGHTCREW_HOLD" = 1 ]; then continue; fi
  hold="$(JOB_PR="$pr" claim hold --labels "$labels" --assignees "$assignees" --hold-labels "$EXTRA_HOLD" --bot "$BOT" 2>>"$LOG")"
  state="${hold%%$'\t'*}"; why="${hold#*$'\t'}"
  remove="$READY"
  case "$state" in
    free)         ;;
    hold-expired) remove="$READY${EXTRA_HOLD:+,$EXTRA_HOLD}"; log "$REPO#$pr: dead hold ($why); reclaiming" ;;
    live)         log "$REPO#$pr: held by a live claim ($why); skipping"; continue ;;
    human)        log "$REPO#$pr: held by a human ($why); skipping"; continue ;;
    hold-pending) log "$REPO#$pr: hold with no live claim ($why); not a human hold, waiting out the grace"; continue ;;
    *)            log "$REPO#$pr: could not read the hold state; skipping"; continue ;;
  esac
  headref_safe "$headref" || { log "$REPO#$pr: head branch '$headref' is not one the pool will push to; skipping"; continue; }
  derive_job "$pr" "$sha" "$headref"
  QUEUE+=("$pr"$'\t'"$headref"$'\t'"$sha"$'\t'"$base"$'\t'"$DJ"$'\t'"$DBASE"$'\t'"${DRHEAD:--}"$'\t'"${DNFIND:--}"$'\t'"$remove"$'\t'"${DWHY:--}")
done
[ "${#QUEUE[@]}" -eq 0 ] && { log "nothing to do after skips"; [ "$SETUP_FAULTS" -gt 0 ] && exit 2; exit 0; }

jobs_run=0; stopped=""
for row in "${QUEUE[@]}"; do
  IFS=$'\t' read -r pr headref sha base job vbase rhead nfind remove SETTLED_WHY <<<"$row"
  [ "$rhead" = - ] && rhead=""; [ "$nfind" = - ] && nfind=""
  if [ "$job" = settled ]; then
    # Settling needs no provider and is no provider job, so neither limit below holds it back.
    if [ "$DRY_RUN" = 1 ]; then log "DRY: would settle $REPO#$pr ($SETTLED_WHY)"
    else run_job "$pr" "$headref" "$sha" "$base" "$job" "$vbase" "$rhead" "$nfind" "$remove" controller; fi
    continue
  fi
  [ -n "$stopped" ] && continue
  [ "$jobs_run" -ge "$MAX_JOBS" ] && continue
  if ! ability_enabled "$job"; then
    log "$REPO#$pr: $job is not an enabled ability for $REPO here (enabled: ${ABILITIES:-none}); skipping"
    continue
  fi
  job_providers "$job"
  if [ "${#JOB_PROVIDERS[@]}" -eq 0 ]; then log "$REPO#$pr: no eligible provider takes $job jobs; skipping"; continue; fi
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY: would claim $REPO#$pr at $sha for $job with providers ${JOB_PROVIDERS[*]}"
  else
    if nightcrew_busy; then
      # One busy answer settles it for the rest of the tick: no more provider jobs, so no more
      # checks (each can cost up to 2 * AGENT_POOL_NIGHTCREW_TIMEOUT + 3 s failing closed).
      log "$REPO#$pr: TheNightCrew holds this repo (rechecked before claim); skipping, only settling from here"
      stopped=1
      continue
    fi
    run_job "$pr" "$headref" "$sha" "$base" "$job" "$vbase" "$rhead" "$nfind" "$remove" "${JOB_PROVIDERS[@]}"
    drop_cooling_providers
    [ "${#PROVIDERS[@]}" -eq 0 ] && { log "every provider is cooling down; only settling from here"; stopped=1; }
  fi
  jobs_run=$((jobs_run + 1))
done
log "tick complete ($jobs_run job(s))"
[ "$SETUP_FAULTS" -gt 0 ] && exit 2
exit 0
