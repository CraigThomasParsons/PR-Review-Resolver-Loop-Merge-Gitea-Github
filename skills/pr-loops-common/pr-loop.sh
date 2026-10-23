#!/usr/bin/env bash
# pr-loop.sh MODE
#
# One tick of the label-driven PR loop for every Gitea repo the pipeline lists. MODE is "review" or "resolve".
#
#   review  : every open PR labelled review:requested gets its own tmux Claude worker that runs
#             /code-review and posts the report as a PR comment. Label moves to review:findings
#             (or review:clean when the report counts zero findings).
#   resolve : every open PR labelled review:findings gets a worker that runs /pr-review-resolver,
#             commits fixes, and pushes fast-forward to the PR branch. Label moves to
#             review:resolved.
#
# The loop itself is deterministic bash: list, filter, spawn, wait, verify, relabel. The model runs
# only inside the workers. Every label change is gated on what gh can verify after the worker
# finishes, never on the worker's own claim of success.
#
# Skips, before any worker is spawned: Dependabot and other bot authors, drafts, PRs whose head
# was already reviewed (hidden marker), and the whole tick when the box is busy or short of memory.
#
# Usage limits: a Claude worker that hits one (HTTP 429, "You've hit your weekly limit", the
# "Stop and wait" menu; see classify-pane.sh's RATE_LIMITED) is killed at the next poll, never
# answered. The limit is recorded with its reset time (provider-fallback.py; six hours when the
# message names none) and until then no tick starts Claude at all. A review then runs under Agy
# instead: `agy --mode plan` with prompts/review.agy.txt and a context file of the diff and PR
# discussion, and the loop posts Agy's response itself, marker and all, so verify() is unchanged.
# Resolve has no fallback (Agy never resolves; it has no deny list): a limited resolve goes back
# to review:findings untouched and waits for the reset.
#
# Never merges, never enables auto-merge, never force-pushes, never deletes branches. The worker
# launch denies those tools; the resolver skill refuses them; and the repo hook denies them again
# once .claude/hooks/pipeline-guardrails.mjs is on develop.
#
# Environment knobs (all optional):
#   DRY_RUN=1          list candidates and print what would happen; spawn nothing, relabel nothing
#   MAX_PARALLEL=2     workers per tick (memory is the constraint on this box)
#   WORKER_TIMEOUT=2700  seconds before a worker is abandoned and the PR marked needs-human
#   POLL=30            seconds between pane checks
#   MIN_FREE_GB=6      skip the tick when less memory than this is available
#   SKIP_BUSY_GUARD=1  run even if another pulse-* tmux worker is mid-task
#   PR_LOOP_WORKTREES  where worker worktrees go (default: .prloop-worktrees next to the clone)
#   PR_LOOP_STATE      lock, log and per-run files (default: ~/.local/state/gitea-pr-loops)
#   PR_LOOP_PR=N       consider only PR #N (the event trigger's drainer sets this); unset = every PR
#   PR_LOOP_LOCK_WAIT=S  wait up to S seconds for the MODE lock instead of exiting at once when a
#                      previous tick holds it; unset = exit at once (the hourly timer's behaviour)
#   PR_LOOP_REMOTE     the remote that carries this repo's PR branches (default: origin). Only
#                      needed when a repo's "origin" is not Gitea -- see TheGiteaCodeFactory,
#                      whose "origin" is its GitHub mirror and whose Gitea remote is "gitea".
#   PR_LOOP_AGY_BIN=agy  the Agy CLI used when Claude is limited; review only. Never a bare `agent`
#   PR_LOOP_AGY_MODEL    --model for Agy (unset = Agy's own default)
#   PR_LOOP_LIMIT_DEFAULT_SECS=21600  how long a limit lasts when its message names no reset
#
# Exit codes: 0 always for a normal tick (including "nothing to do"); 2 for a setup fault.

set -uo pipefail

# Run from a private copy of this file.
#
# Bash reads a script by byte offset as it goes, so editing this file while a tick is running makes
# the running tick seek into the wrong place once it leaves the compound command it is inside. It
# happened: an edit during a live review tick left the loop executing a fragment of a function it
# had never parsed. The work had already finished by then, but the tick died on the fragment
# instead of logging its own completion. A tick that lasts three quarters of an hour will overlap
# an edit sooner or later, so it gets its own copy and the file on disk is free to change.
# The copy lives in a temp directory, so the real location is recorded first; everything the loop
# ships with (prompts, marker.py, classify-pane.sh) is found relative to it.
if [ -z "${PR_LOOP_PINNED:-}" ]; then
  PR_LOOP_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  export PR_LOOP_HOME
  pinned="$(mktemp -t pr-loop.XXXXXX.sh)"
  cat "${BASH_SOURCE[0]}" > "$pinned"
  export PR_LOOP_PINNED="$pinned"
  bash "$pinned" "$@"
  rc=$?
  rm -f "$pinned"
  exit $rc
fi

MODE="${1:-}"
case "$MODE" in review|resolve) ;; *) echo "usage: pr-loop.sh review|resolve" >&2; exit 2 ;; esac

# ---------------------------------------------------------------- configuration
REPO="${PR_LOOP_REPO:-craigpars/AgileMedievalPeasantBoard}"
COMMON="$PR_LOOP_HOME"
ADAPTER="$COMMON/gitea-pr.py"   # Gitea replacement for every gh call
# The main checkout, even when this script is run from a linked worktree: worker worktrees are
# added from it and must outlive whichever worktree launched the tick.
# Upstream lived inside the repo (.agents/skills/...) and found the clone from its own
# location. This copy lives in ~/.claude/skills, which is not a git repo, and it serves 32
# repos rather than one -- so the checkout is named explicitly. PR_LOOP_MAIN wins; otherwise
# fall back to the script's own location for anyone who does vendor it into a repo.
MAIN="${PR_LOOP_MAIN:-}"
if [ -z "$MAIN" ]; then
  MAIN="$(git -C "$COMMON" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  MAIN="${MAIN%/.git}"
fi
# The remote that actually carries this repo's PR branches. Every repo in this estate but one
# has "origin" pointing at Gitea; TheGiteaCodeFactory's "origin" is its GitHub mirror, with the
# Gitea remote named "gitea" instead -- a hardcoded "origin" there fetches a branch that isn't
# there and fails every time, not intermittently. PR_LOOP_REMOTE lets that one repo's invocation
# say so without changing the default for everyone else.
PR_LOOP_REMOTE="${PR_LOOP_REMOTE:-origin}"
WT_ROOT="${PR_LOOP_WORKTREES:-$(dirname "$MAIN")/.prloop-worktrees}"
mkdir -p "$WT_ROOT"
STATE="${PR_LOOP_STATE:-$HOME/.local/state/gitea-pr-loops}"
LOG="$STATE/pr-loop.log"
MAX_PARALLEL="${MAX_PARALLEL:-2}"
WORKER_TIMEOUT="${WORKER_TIMEOUT:-2700}"
POLL="${POLL:-30}"
MIN_FREE_GB="${MIN_FREE_GB:-6}"
DRY_RUN="${DRY_RUN:-0}"
SKIP_BUSY_GUARD="${SKIP_BUSY_GUARD:-0}"
ONLY_PR="${PR_LOOP_PR:-}"
LOCK_WAIT="${PR_LOOP_LOCK_WAIT:-}"
CLASSIFY="$COMMON/classify-pane.sh"
FALLBACK="$COMMON/provider-fallback.py"
AGY="${PR_LOOP_AGY_BIN:-agy}"
AGY_PROMPT="$COMMON/prompts/review.agy.txt"
LIMIT_DEFAULT_SECS="${PR_LOOP_LIMIT_DEFAULT_SECS:-21600}"
CONTEXT_FILE=".pr-loop-context.md"

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

case "$MODE" in
  review)
    TRIGGER="review:requested"; CLAIM="review:in-progress"; OK="review:findings"; CLEAN="review:clean"
    SENTINEL="PR_REVIEW_DONE"; PROMPT_TMPL="$COMMON/prompts/review.txt" ;;
  resolve)
    TRIGGER="review:findings"; CLAIM="review:resolving"; OK="review:resolved"; CLEAN=""
    SENTINEL="PR_RESOLVE_DONE"; PROMPT_TMPL="$COMMON/prompts/resolve.txt" ;;
esac
FAIL="review:needs-human"

# Tools the worker may use without a prompt. Auto mode's classifier covers the rest; the deny list
# below is what it may never do, whatever mode it is in.
ALLOW_COMMON=(Read Grep Glob Agent
  "Bash(git log *)" "Bash(git diff *)" "Bash(git show *)" "Bash(git status *)" "Bash(git rev-parse *)"
  "Bash(git merge-base *)" "Bash(git fetch *)" "Bash(git branch *)"
  "Bash(tea pr list *)" "Bash(tea comments list *)"   # read-only tea
  # PR reads/writes go through the adapter; Bash(python3 *) below already reaches it.
  "Bash(python3 *)" "Bash(node *)" "Bash(cat *)" "Bash(sed *)" "Bash(wc *)" "Bash(ls *)" "Bash(head *)" "Bash(tail *)")
ALLOW_RESOLVE=(Edit Write MultiEdit
  "Bash(git add *)" "Bash(git commit *)" "Bash(git push $PR_LOOP_REMOTE HEAD:*)"
  "Bash(npm run *)" "Bash(npm ci *)" "Bash(npx *)" "Bash(dotnet build *)" "Bash(dotnet test *)" "Bash(just *)"
  "Bash(composer test*)" "Bash(composer lint*)" "Bash(php artisan test*)" "Bash(vendor/bin/pint *)" "Bash(vendor/bin/phpunit*)")
DENY=("Bash(tea pr merge *)" "Bash(tea pr approve *)" "Bash(tea pr close *)" "Bash(tea pr reject *)"
  "Bash(gh pr merge *)" "Bash(git push * --force*)" "Bash(git push * -f *)" "Bash(git push --force*)"
  "Bash(git reset --hard *)" "Bash(git branch -D *)" "Bash(git push * --delete *)" "Bash(gh api *auto*merge*)"
  "Bash(gh pr ready *)" "Bash(gh pr edit *)" "Bash(gh pr close *)" "Bash(sudo *)" "Bash(rm -rf *)"
  # Only the loop relabels; a worker moving its own label would defeat the marker gate.
  # NB: no blanket *merge* pattern -- it would also block git merge-base, which is allowed.
  "Bash(*gitea-pr.py label*)" "Bash(*gitea-pr.py merge*)" "Bash(tea pr edit *)")

mkdir -p "$STATE" "$WT_ROOT"
log() { printf '%s [%s] [%s] %s\n' "$(date -Is)" "$MODE" "$REPO" "$*" | tee -a "$LOG" >&2; }
die() { log "FATAL: $*"; exit 2; }

# ---------------------------------------------------------------- preconditions
[ -z "$ONLY_PR" ] || [[ "$ONLY_PR" =~ ^[1-9][0-9]*$ ]] || die "PR_LOOP_PR must be a PR number (got '$ONLY_PR')"
[ -z "$LOCK_WAIT" ] || [[ "$LOCK_WAIT" =~ ^[0-9]+$ ]] || die "PR_LOOP_LOCK_WAIT must be whole seconds (got '$LOCK_WAIT')"
[[ "$LIMIT_DEFAULT_SECS" =~ ^[1-9][0-9]*$ ]] || die "PR_LOOP_LIMIT_DEFAULT_SECS must be whole seconds (got '$LIMIT_DEFAULT_SECS')"
command -v claude >/dev/null || die "claude not on PATH"
command -v tea >/dev/null || [ -x "$HOME/.local/bin/tea" ] || die "tea not on PATH"
[ -f "$ADAPTER" ] || die "missing Gitea adapter: $ADAPTER"
command -v tmux >/dev/null || die "tmux not on PATH"
[ -x "$CLASSIFY" ] || die "missing or not executable: $CLASSIFY"
[ -f "$PROMPT_TMPL" ] || die "missing prompt template $PROMPT_TMPL"
[ -n "$MAIN" ] && [ -e "$MAIN/.git" ] || die "no checkout for $REPO: set PR_LOOP_MAIN to its clone (got '$MAIN')"

exec 9>"$STATE/$MODE.lock"
if [ -z "$LOCK_WAIT" ]; then
  if ! flock -n 9; then log "previous $MODE tick still running; exiting"; exit 0; fi
elif ! flock -n 9; then
  log "previous $MODE tick still running; waiting up to ${LOCK_WAIT}s for it"
  if ! flock -w "$LOCK_WAIT" 9; then log "gave up waiting ${LOCK_WAIT}s for the $MODE lock; exiting"; exit 0; fi
fi

if [ "$DRY_RUN" != "1" ]; then
  if [ "$SKIP_BUSY_GUARD" != "1" ]; then
    # A run launched by hand from inside a pulse-* pane would otherwise see that pane running this
    # very script and call the box busy on account of itself. Cron has no session, so $TMUX is
    # empty there and nothing is excluded.
    SELF="$(tmux display-message -p '#{session_name}' 2>/dev/null || true)"
    for s in $(tmux ls -F '#{session_name}' 2>/dev/null | grep -E '^(pulse-|ampb-)'); do
      [ "$s" = "$SELF" ] && continue
      if tmux capture-pane -t "$s" -p 2>/dev/null | grep -q 'esc to interrupt'; then
        log "box busy: tmux session $s is mid-task; skipping this tick"; exit 0
      fi
    done
  fi
  free_gb="$(free -g | awk '/^Mem:/{print $7}')"
  if [ "${free_gb:-0}" -lt "$MIN_FREE_GB" ]; then
    log "only ${free_gb}G available (< ${MIN_FREE_GB}G); skipping this tick"; exit 0
  fi
fi

git -C "$MAIN" fetch "$PR_LOOP_REMOTE" --quiet --prune || log "warning: fetch failed; continuing with what is local"

# ---------------------------------------------------------------- candidates
# Bots (Dependabot included) and drafts never reach a worker. review mode also skips a head that
# already carries a marker; resolve mode requires the marker to name the CURRENT head, otherwise
# the findings are stale and the PR goes back to review:requested.
# Filtered client-side on labels[].name rather than with --label: the --label form goes through
# GitHub's search index, which can lag a label edit by seconds, and this list must reflect the
# labels as they are right now.
# A failing gh call must be a fault, not an empty list; otherwise a broken query reads as "nothing
# to do" and the loop silently never reviews anything.
if ! LISTING="$(TRIGGER="$TRIGGER" python3 "$ADAPTER" list --repo "$REPO" --state open \
  | TRIGGER="$TRIGGER" ONLY_PR="$ONLY_PR" python3 -c '
import json, os, re, sys
trigger = os.environ["TRIGGER"]
only = os.environ.get("ONLY_PR", "")
# Gitea has no is_bot flag and AMPB nightly PRs are authored by craigpars, so the
# upstream dependabot check cannot catch them. Skip by pattern instead.
raw = os.environ.get("PR_LOOP_SKIP_PATTERN", r"docblock-backfill|^chore\(#152\)")
rx = re.compile(raw) if raw else None
for pr in json.load(sys.stdin):
    if only and str(pr["number"]) != only: continue
    if trigger not in pr["labels"]:      continue
    if pr["draft"] or pr["is_bot"]:      continue
    if rx and (rx.search(pr["title"]) or rx.search(pr["head_ref"])): continue
    print("\t".join([str(pr["number"]), pr["head_ref"], pr["head_sha"], pr["base_ref"]]))
')"; then
  die "gitea pr list failed; not treating that as an empty queue"
fi
mapfile -t CANDIDATES < <(printf '%s\n' "$LISTING" | sed '/^$/d')

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  if [ -n "$ONLY_PR" ]; then log "#$ONLY_PR is not an open, non-draft, non-bot PR carrying $TRIGGER"
  else log "no open, non-draft, non-bot PR carries $TRIGGER"; fi
  exit 0
fi

relabel() { # pr from to
  if [ "$DRY_RUN" = "1" ]; then log "DRY: #$1 $2 -> $3"; return 0; fi
  python3 "$ADAPTER" label --repo "$REPO" --pr "$1" --remove "$2" --add "$3" >/dev/null 2>&1 || log "warning: relabel #$1 $2 -> $3 failed"
}
comment() { # pr body
  if [ "$DRY_RUN" = "1" ]; then log "DRY: would comment on #$1: $2"; return 0; fi
  local bf; bf="$(mktemp)"; printf '%s\n' "$2" > "$bf"
  python3 "$ADAPTER" comment --repo "$REPO" --pr "$1" --body-file "$bf" >/dev/null 2>&1 || log "warning: comment on #$1 failed"
  rm -f "$bf"
}

# ---------------------------------------------------------------- usage limits and the Agy fallback
claude_limited() { # -> 0 while a recorded Claude limit stands, with LIMIT_UNTIL set
  local rec
  rec="$(python3 "$FALLBACK" limit-check --state "$STATE" --provider claude 2>/dev/null)" || return 1
  IFS=$'\t' read -r _ LIMIT_UNTIL _ <<<"$rec"
}
agy_ready() { # -> 0 when the Agy review fallback can run; otherwise AGY_WHY says why not
  AGY_WHY=""
  [ "$(basename -- "$AGY")" = agent ] && AGY_WHY="refusing a bare 'agent' binary (Cursor's alias)"
  command -v "$AGY" >/dev/null 2>&1 || AGY_WHY="${AGY_WHY:-$AGY is not on PATH}"
  [ -f "$AGY_PROMPT" ] || AGY_WHY="${AGY_WHY:-missing $AGY_PROMPT}"
  [ -f "$FALLBACK" ] || AGY_WHY="${AGY_WHY:-missing $FALLBACK}"
  [ -z "$AGY_WHY" ]
}
# The provider's own last words, for the log and the needs-human comment: its error lines when it
# printed any, otherwise its last lines. Home paths are shortened and code fences defused.
text_excerpt() { # text
  local pick line
  pick="$(printf '%s\n' "$1" | grep -E '[Ee]rror|\b429\b|[Ll]imit|[Ff]ailed|[Dd]enied|Stop and wait|Wait here|PR_LOOP_WORKER_EXIT')" \
    || pick="$(printf '%s\n' "$1" | grep -v '^[[:space:]]*$')"
  printf '%s\n' "$pick" | tail -n 12 | while IFS= read -r line; do
    line="${line//"$HOME"/'~'}"; line="${line//'```'/"'''"}"
    printf '%s\n' "${line:0:300}"
  done
}
pane_excerpt() { # session
  text_excerpt "$(tmux capture-pane -t "$1" -p -S -40 2>/dev/null)"
}

declare -a QUEUE=()
for row in "${CANDIDATES[@]}"; do
  IFS=$'\t' read -r pr headref sha base <<<"$row"
  marker="$(python3 "$COMMON/marker.py" latest "$pr" 2>/dev/null || true)"
  mhead="${marker%% *}"
  if [ "$MODE" = "review" ] && [ "$mhead" = "$sha" ]; then
    log "#$pr head $sha already reviewed (marker); skipping"; continue
  fi
  if [ "$MODE" = "resolve" ] && [ "$mhead" != "$sha" ]; then
    log "#$pr findings are for $mhead but head is $sha; stale, sending back to review:requested"
    relabel "$pr" "$TRIGGER" "review:requested"; continue
  fi
  QUEUE+=("$row")
done
if [ "${#QUEUE[@]}" -eq 0 ]; then log "nothing to do after skips"; exit 0; fi

# ---------------------------------------------------------------- workers
# W_SESS is every live worker's name (a tmux session for claude); W_PROV says which provider it is.
# Assigned empty, not just declared: under set -u, ${#W_SESS[@]} of a declared-only array is unbound.
declare -A W_SESS=() W_WT=() W_SHA=() W_HEADREF=() W_BASE=() W_PROV=() W_PID=() W_START=() W_STALLS=() W_BLOCKS=()
spawned=0

# Mark a worktree path trusted in ~/.claude.json so Claude Code skips the
# "I trust this folder" dialog (default No/exit) that otherwise kills the pane
# and produces a false review:needs-human. Claude stores trust per exact path;
# trusting the parent WT_ROOT alone is not enough for a new prloop-* worktree.
pretrust_worktree() {
  local wt="$1"
  python3 - "$wt" "$WT_ROOT" <<'PY'
import json, os, sys, tempfile
from pathlib import Path

paths = [p for p in sys.argv[1:] if p]
cfg = Path.home() / ".claude.json"
if not cfg.is_file():
    sys.exit(0)

data = json.loads(cfg.read_text())
projects = data.setdefault("projects", {})
template = {
    "allowedTools": [],
    "mcpContextUris": [],
    "mcpServers": {},
    "enabledMcpjsonServers": [],
    "disabledMcpjsonServers": [],
    "hasTrustDialogAccepted": True,
    "hasClaudeMdExternalIncludesApproved": False,
    "hasClaudeMdExternalIncludesWarningShown": False,
}
changed = False
for path in paths:
    entry = projects.get(path)
    if not isinstance(entry, dict):
        projects[path] = dict(template)
        changed = True
        continue
    if entry.get("hasTrustDialogAccepted") is not True:
        entry["hasTrustDialogAccepted"] = True
        changed = True
if not changed:
    sys.exit(0)

fd, tmp = tempfile.mkstemp(prefix=".claude.json.", dir=str(cfg.parent))
try:
    with os.fdopen(fd, "w") as out:
        json.dump(data, out, indent=2)
        out.write("\n")
    os.replace(tmp, cfg)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
}


render_prompt() { # template out pr headref sha base [context]
  sed -e "s|__PR__|$3|g" -e "s|__HEADREF__|$4|g" -e "s|__SHA__|$5|g" -e "s|__BASE__|$6|g" -e "s|__SENTINEL__|$SENTINEL|g" -e "s|__REPO__|$REPO|g" -e "s|__ADAPTER__|$ADAPTER|g" -e "s|__COMMON__|$COMMON|g" -e "s|__CONTEXT__|${7:-}|g" \
    "$1" > "$2"
}

# What Agy cannot fetch for itself in plan mode, where every command is denied. A file, not an
# argument: one argument over 128 KiB fails exec with E2BIG.
write_context() { # pr wt sha base
  {
    printf '# Context for PR #%s at %s (base %s), gathered by the PR loop\n\n' "$1" "$3" "$4"
    printf '## Commits (git log %s/%s..%s)\n\n```\n' "$PR_LOOP_REMOTE" "$4" "$3"
    git -C "$MAIN" log --format='%h %s' "$PR_LOOP_REMOTE/$4..$3" 2>/dev/null
    printf '```\n\n## Diff (git diff %s/%s...%s)\n\n```diff\n' "$PR_LOOP_REMOTE" "$4" "$3"
    git -C "$MAIN" diff "$PR_LOOP_REMOTE/$4...$3" 2>/dev/null
    printf '```\n\n## PR comments (JSON)\n\n```json\n'
    python3 "$ADAPTER" comments --repo "$REPO" --pr "$1" 2>/dev/null || echo '[] (could not read the comments)'
    printf '```\n'
  } > "$2/$CONTEXT_FILE"
}

# Run the review of an already-claimed PR under Agy, in the background. The worktree and W_* entries
# must already exist. stdin is /dev/null and `timeout` bounds it: Agy never gets a menu to sit on.
start_agy() { # pr
  local pr="$1"
  local wt="${W_WT[$pr]}" sha="${W_SHA[$pr]}" run="$STATE/agy-$MODE-$pr"
  local cmd=("$AGY" -p "" --output-format json --print-timeout 0 --mode plan)
  rm -f "$run.out" "$run.err" "$run.rc" "$run.report"
  write_context "$pr" "$wt" "$sha" "${W_BASE[$pr]}"
  render_prompt "$AGY_PROMPT" "$run.prompt" "$pr" "${W_HEADREF[$pr]}" "$sha" "${W_BASE[$pr]}" "$wt/$CONTEXT_FILE"
  cmd[2]="$(cat "$run.prompt")"
  [ -n "${PR_LOOP_AGY_MODEL:-}" ] && cmd+=(--model "$PR_LOOP_AGY_MODEL")
  (
    cd "$wt" && timeout -k 30 "$WORKER_TIMEOUT" "${cmd[@]}" </dev/null >"$run.out" 2>"$run.err"
    echo $? > "$run.rc.tmp" && mv "$run.rc.tmp" "$run.rc"
  ) &
  W_PID[$pr]=$!; W_PROV[$pr]=agy; W_SESS[$pr]="agy-$MODE-$pr"
  W_START[$pr]="$(date +%s)"; W_STALLS[$pr]=0; W_BLOCKS[$pr]=0
  log "#$pr: started agy review in $wt at $sha"
}
stop_agy() { # pr
  local pid="${W_PID[$1]:-}"
  [ -n "$pid" ] || return 0
  pkill -TERM -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  return 0
}

spawn() { # row
  IFS=$'\t' read -r pr headref sha base <<<"$1"
  local sess="prloop-$MODE-$pr" wt="$WT_ROOT/prloop-$MODE-$pr" prompt="$STATE/prompt-$MODE-$pr.txt" launch="$STATE/launch-$MODE-$pr.sh"
  local use=claude
  if claude_limited; then
    if [ "$MODE" = resolve ]; then
      log "#$pr: Claude is limited until $LIMIT_UNTIL and resolve has no fallback; leaving it at $TRIGGER"; return 1
    fi
    if ! agy_ready; then
      log "#$pr: Claude is limited until $LIMIT_UNTIL and the Agy fallback is unavailable ($AGY_WHY); leaving it at $TRIGGER"; return 1
    fi
    use=agy
  fi
  if [ "$DRY_RUN" = "1" ]; then
    if [ "$use" = agy ]; then log "DRY: would spawn agy for #$pr at $sha ($headref -> $base); Claude is limited until $LIMIT_UNTIL"
    else log "DRY: would spawn $sess at $sha ($headref -> $base)"; fi
    return 0
  fi
  if [ "$use" = claude ] && tmux has-session -t "$sess" 2>/dev/null; then log "#$pr: session $sess already exists; leaving it alone"; return 1; fi
  relabel "$pr" "$TRIGGER" "$CLAIM"
  git -C "$MAIN" fetch "$PR_LOOP_REMOTE" --quiet "$headref" || { log "#$pr: fetch $headref failed"; relabel "$pr" "$CLAIM" "$FAIL"; return 1; }
  [ -d "$wt" ] && git -C "$MAIN" worktree remove --force "$wt" >/dev/null 2>&1
  git -C "$MAIN" worktree add --detach "$wt" "$sha" >/dev/null 2>&1 || { log "#$pr: worktree add failed"; relabel "$pr" "$CLAIM" "$FAIL"; return 1; }
  W_WT[$pr]="$wt"; W_SHA[$pr]="$sha"; W_HEADREF[$pr]="$headref"; W_BASE[$pr]="$base"
  if [ "$use" = agy ]; then
    log "#$pr: Claude is limited until $LIMIT_UNTIL; reviewing with agy"
    start_agy "$pr"; return 0
  fi
  pretrust_worktree "$wt"
  render_prompt "$PROMPT_TMPL" "$prompt" "$pr" "$headref" "$sha" "$base"
  # Not exec: when claude exits, the pane stays up long enough for the loop to read why.
  {
    echo '#!/usr/bin/env bash'
    printf 'cd %q\n' "$wt"
    printf 'claude --permission-mode auto'
    printf ' --allowedTools'; for t in "${ALLOW_COMMON[@]}"; do printf ' %q' "$t"; done
    if [ "$MODE" = "resolve" ]; then for t in "${ALLOW_RESOLVE[@]}"; do printf ' %q' "$t"; done; fi
    printf ' --disallowedTools'; for t in "${DENY[@]}"; do printf ' %q' "$t"; done
    echo
    echo 'printf "\nPR_LOOP_WORKER_EXIT=%s\n" "$?"'
    echo 'exec sleep 600'
  } > "$launch"; chmod +x "$launch"
  tmux new-session -d -s "$sess" -c "$wt" "$launch"
  # wait for the prompt box, then paste the prompt and submit it.
  # Claude may first show a workspace-trust dialog whose default is "No, exit";
  # that dialog also contains ❯, so treat it explicitly: pick "Yes, I trust this folder".
  local i pane
  for i in $(seq 1 30); do
    pane="$(tmux capture-pane -t "$sess" -p 2>/dev/null || true)"
    if printf '%s\n' "$pane" | grep -q 'I trust this folder'; then
      tmux send-keys -t "$sess" Down; sleep 0.3; tmux send-keys -t "$sess" Enter
      sleep 2
      continue
    fi
    printf '%s\n' "$pane" | grep -qE '❯|for agents' && break
    sleep 2
  done
  tmux load-buffer -b "prloop-$pr" "$prompt"
  tmux paste-buffer -b "prloop-$pr" -t "$sess" -d
  sleep 2; tmux send-keys -t "$sess" Enter
  for i in $(seq 1 15); do tmux capture-pane -t "$sess" -p 2>/dev/null | grep -q 'esc to interrupt' && break; sleep 2; done
  # The nudge Enter must never land on a limit menu: it would choose "Stop and wait".
  if ! tmux capture-pane -t "$sess" -p 2>/dev/null | grep -q 'esc to interrupt' \
     && [ "$("$CLASSIFY" "$sess" "$SENTINEL" 40 2>/dev/null | head -1)" != STATE=RATE_LIMITED ]; then
    tmux send-keys -t "$sess" Enter; sleep 5
  fi
  W_SESS[$pr]="$sess"; W_PROV[$pr]=claude; W_START[$pr]="$(date +%s)"; W_STALLS[$pr]=0; W_BLOCKS[$pr]=0
  rm -f "$STATE/classify-$sess.state"
  log "#$pr: spawned $sess in $wt at $sha"
}

finish() { # pr outcome reason [provider output]
  local pr="$1" outcome="$2" reason="$3" detail="${4:-}" sess="${W_SESS[$pr]}" wt="${W_WT[$pr]}" said=""
  if [ "${W_PROV[$pr]}" = agy ]; then stop_agy "$pr"; else tmux kill-session -t "$sess" 2>/dev/null; fi
  [ -n "$detail" ] && printf -v said '\n\n%s said:\n\n```\n%s\n```' "${W_PROV[$pr]}" "$detail"
  case "$outcome" in
    ok)    relabel "$pr" "$CLAIM" "$OK" ;;
    clean) relabel "$pr" "$CLAIM" "$CLEAN" ;;
    fail)  relabel "$pr" "$CLAIM" "$FAIL"; comment "$pr" "Automated $MODE loop stopped on this PR: $reason. A human needs to look; the loop log on the review host has the detail.$said" ;;
    requeue) relabel "$pr" "$CLAIM" "$TRIGGER"; comment "$pr" "Automated $MODE loop paused on this PR: $reason. It is back at $TRIGGER for a later tick.$said" ;;
  esac
  rm -f "$wt/$CONTEXT_FILE"
  if git -C "$MAIN" worktree remove "$wt" >/dev/null 2>&1; then :; else log "#$pr: worktree $wt kept (uncommitted changes or busy); inspect and remove by hand"; fi
  rm -f "$STATE/classify-$sess.state" "$STATE/launch-$MODE-$pr.sh" "$STATE/agy-$MODE-$pr.rc" "$STATE/agy-$MODE-$pr.prompt" "$STATE/agy-$MODE-$pr.report"
  log "#$pr: $outcome ($reason)"
  [ -n "$detail" ] && printf '%s\n' "$detail" | sed 's/^/    | /' | tee -a "$LOG" >&2
  unset "W_SESS[$pr]" "W_WT[$pr]" "W_SHA[$pr]" "W_HEADREF[$pr]" "W_BASE[$pr]" "W_PROV[$pr]" "W_PID[$pr]" "W_START[$pr]" "W_STALLS[$pr]" "W_BLOCKS[$pr]"
}

# A Claude worker hit a usage limit: kill it now (it would sit on the limit menu until
# WORKER_TIMEOUT), remember the limit so later ticks skip Claude, and hand the review to Agy.
claude_hit_limit() { # pr
  local pr="$1" sess="${W_SESS[$pr]}" cap="$STATE/limit-${W_SESS[$pr]}.txt" rec until_iso="an unknown time" source detail
  tmux capture-pane -t "$sess" -p -S -200 > "$cap" 2>/dev/null
  tmux kill-session -t "$sess" 2>/dev/null
  detail="$(text_excerpt "$(tail -n 40 "$cap")")"
  if rec="$(python3 "$FALLBACK" limit-record --state "$STATE" --provider claude --text-file "$cap" --default-secs "$LIMIT_DEFAULT_SECS")"; then
    IFS=$'\t' read -r _ until_iso source <<<"$rec"
    log "#$pr: Claude hit a usage limit; killed $sess; Claude is skipped until $until_iso ($source)"
  else
    log "#$pr: Claude hit a usage limit; killed $sess; warning: the limit could not be recorded"
  fi
  rm -f "$cap" "$STATE/classify-$sess.state"
  if [ "$MODE" = resolve ]; then
    finish "$pr" requeue "Claude hit its usage limit (skipped until $until_iso) and resolve has no fallback provider" "$detail"
  elif agy_ready; then
    log "#$pr: falling back to agy"
    start_agy "$pr"
  else
    finish "$pr" fail "Claude hit its usage limit (skipped until $until_iso) and the Agy fallback is unavailable: $AGY_WHY" "$detail"
  fi
}

poll_agy() { # pr
  local pr="$1" run="$STATE/agy-$MODE-$pr" res v
  if [ ! -f "$run.rc" ]; then
    # timeout(1) inside start_agy is the real clock; this only catches a wrapper that never returns.
    if [ $(( $(date +%s) - W_START[$pr] )) -gt $(( WORKER_TIMEOUT + 60 )) ]; then
      finish "$pr" fail "the Agy fallback review never returned" "$(text_excerpt "$(cat "$run.err" 2>/dev/null)")"
    fi
    return
  fi
  res="$(python3 "$FALLBACK" agy-result --rc "$(cat "$run.rc")" --stdout "$run.out" --stderr "$run.err" \
    --sha "${W_SHA[$pr]}" --report-out "$run.report" 2>&1)"
  if [ "${res%%$'\t'*}" != ok ]; then
    finish "$pr" fail "Claude is limited and the Agy fallback review failed" "${res#*$'\t'}"; return
  fi
  comment "$pr" "$(cat "$run.report")"
  v="$(verify "$pr")"
  case "$v" in
    ok) finish "$pr" ok "verified (agy)" ;;
    clean) finish "$pr" clean "zero findings (agy)" ;;
    *) finish "$pr" fail "${v#fail:} (agy)" ;;
  esac
}

verify() { # pr -> prints ok|clean|fail:<reason>
  # Declared separately: bash expands a whole `local a=... b=${x[$a]}` word list before making any
  # of the assignments, so the array lookups would read whatever `pr` happened to be in the
  # caller's scope. It worked only because the caller's loop variable is also called pr.
  local pr="$1"
  local sha="${W_SHA[$pr]}"
  local headref="${W_HEADREF[$pr]}"
  if [ "$MODE" = "review" ]; then
    local m; m="$(python3 "$COMMON/marker.py" latest "$pr" 2>/dev/null || true)"
    if [ "${m%% *}" != "$sha" ]; then echo "fail:worker finished but no review comment carrying the marker for $sha was found"; return; fi
    if [ "${m##* }" = "0" ]; then echo clean; else echo ok; fi
  else
    # A pushed commit says work happened, not that the findings were dealt with. The first live
    # run fixed two findings, left a third as a human decision, and this function said "ok" purely
    # because the head had moved. So the head check stays, and the disposition is checked too.
    local newsha; newsha="$(python3 "$ADAPTER" head --repo "$REPO" --pr "$pr" 2>/dev/null)"
    if [ -z "$newsha" ]; then echo "fail:could not read the PR head after the run"; return; fi
    # verify() is extracted standalone by the test harness (sed between the function markers),
    # without the top-level default assignment in scope, so the fallback is inlined here too.
    git -C "$MAIN" fetch "${PR_LOOP_REMOTE:-origin}" --quiet "$headref"

    local rm; rm="$(python3 "$COMMON/marker.py" resolve "$pr" 2>/dev/null || true)"
    if [ -z "$rm" ]; then echo "fail:the resolver left no disposition marker, so what it did to each finding is unknown"; return; fi
    local r_head r_reviewed r_fixed r_deferred r_noted
    read -r r_head r_reviewed r_fixed r_deferred r_noted <<<"$rm"
    r_noted="${r_noted:-0}"   # markers written before noted= existed

    # The disposition must answer the review that triggered this run, not an older one.
    local review; review="$(python3 "$COMMON/marker.py" latest "$pr" 2>/dev/null || true)"
    local review_head="${review%% *}" review_count="${review##* }"
    if [ "$r_reviewed" != "$review_head" ]; then
      echo "fail:the resolver answered a review of $r_reviewed but the findings on this PR are from $review_head"; return
    fi
    if [ "$((r_fixed + r_noted + r_deferred))" -ne "${review_count:-0}" ]; then
      echo "fail:the review raised $review_count finding(s) but the resolver accounted for $((r_fixed + r_noted + r_deferred))"; return
    fi

    # Nothing fixed means nothing should have been pushed, and vice versa.
    if [ "$r_fixed" -gt 0 ]; then
      if [ "$newsha" = "$sha" ]; then echo "fail:the resolver claims $r_fixed fix(es) but the PR head never moved"; return; fi
      if [ "$r_head" != "$newsha" ]; then echo "fail:the resolver named head $r_head but the PR is at $newsha"; return; fi
      if ! git -C "$MAIN" merge-base --is-ancestor "$sha" "$newsha"; then
        echo "fail:the PR head moved to $newsha but not as a fast-forward of $sha"; return
      fi
    elif [ "$newsha" != "$sha" ]; then
      echo "fail:the resolver claims no fixes yet the PR head moved to $newsha"; return
    fi

    # A blocking finding left for a person is not resolved, however well the push went. Noted
    # findings (suggestions, conventions, process ideas) do not block: they are listed in the
    # resolver's comment for the author, and the PR still reaches review:resolved. Before this
    # split every design-flavoured remark counted as deferred, so a sound docs PR with five
    # preferences in its review landed on needs-human.
    if [ "$r_deferred" -gt 0 ]; then
      echo "fail:$r_deferred of $review_count finding(s) are blocking and need a human decision; $r_fixed fixed, $r_noted noted"; return
    fi
    echo ok
  fi
}

# spawn the first batch
pretrust_worktree "$WT_ROOT"
for row in "${QUEUE[@]}"; do
  [ "$spawned" -ge "$MAX_PARALLEL" ] && break
  spawn "$row" && spawned=$((spawned + 1))
done
if [ "$DRY_RUN" = "1" ]; then log "DRY: ${#QUEUE[@]} candidate(s), would run up to $MAX_PARALLEL in parallel"; exit 0; fi
[ "${#W_SESS[@]}" -eq 0 ] && { log "no worker started"; exit 0; }

# supervise until every worker has finished or timed out
while [ "${#W_SESS[@]}" -gt 0 ]; do
  sleep "$POLL"
  for pr in "${!W_SESS[@]}"; do
    if [ "${W_PROV[$pr]}" = agy ]; then poll_agy "$pr"; continue; fi
    sess="${W_SESS[$pr]}"
    if ! tmux has-session -t "$sess" 2>/dev/null; then finish "$pr" fail "the worker session disappeared"; continue; fi
    if [ $(( $(date +%s) - W_START[$pr] )) -gt "$WORKER_TIMEOUT" ]; then finish "$pr" fail "worker exceeded ${WORKER_TIMEOUT}s" "$(pane_excerpt "$sess")"; continue; fi
    state="$("$CLASSIFY" "$sess" "$SENTINEL" 40 "$STATE/classify-$sess.state" 2>/dev/null | head -1)"
    case "$state" in
      STATE=WORKING) W_STALLS[$pr]=0; W_BLOCKS[$pr]=0 ;;
      STATE=DONE)
        v="$(verify "$pr")"
        case "$v" in ok) finish "$pr" ok "verified";; clean) finish "$pr" clean "zero findings";; *) finish "$pr" fail "${v#fail:}" "$(pane_excerpt "$sess")";; esac ;;
      STATE=RATE_LIMITED) claude_hit_limit "$pr" ;;
      STATE=EXITED) finish "$pr" fail "Claude exited before finishing" "$(pane_excerpt "$sess")" ;;
      STATE=PARKED) finish "$pr" fail "Claude Code is parked on a product dialog (login or setup)" "$(pane_excerpt "$sess")" ;;
      STATE=BLOCKED)
        W_BLOCKS[$pr]=$(( W_BLOCKS[$pr] + 1 ))
        [ "${W_BLOCKS[$pr]}" -ge 3 ] && finish "$pr" fail "worker is waiting on a prompt or menu the loop will not answer" "$(pane_excerpt "$sess")" ;;
      STATE=STALLED)
        W_STALLS[$pr]=$(( W_STALLS[$pr] + 1 ))
        if [ "${W_STALLS[$pr]}" -eq 1 ]; then
          tmux send-keys -t "$sess" "continue - finish the task, then print $SENTINEL on its own line"; sleep 1; tmux send-keys -t "$sess" Enter
          log "#$pr: nudged"
        else finish "$pr" fail "worker stalled twice" "$(pane_excerpt "$sess")"; fi ;;
      *) : ;;
    esac
  done
done
log "tick complete"
exit 0
