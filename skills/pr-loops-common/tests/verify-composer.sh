#!/usr/bin/env bash
# Offline cases for the composer install step that runs in a PR's worktree before its worker
# starts: which directories get installed, the PR_LOOP_COMPOSER_* knobs, and what a failure says.
#
# The first half calls the real install_composer_deps() lifted out of pr-loop.sh (with the real
# log and text_excerpt it uses) against temp worktrees and a stub composer named by
# PR_LOOP_COMPOSER_BIN. Then the real finish() removes a worktree holding an untracked vendor/
# from a throwaway local git repo. The last part runs whole review ticks with claude, tea, tmux and
# git stubbed, as tests/verify-fallback.sh does, to show a failed install stops the PR without ever
# starting a worker. No network, no remote repository, no real composer.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LOOP="$ROOT/pr-loop.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
BIN="$HOME/.local/bin"
mkdir -p "$BIN"
export PATH="$BIN:$PATH"
unset PR_LOOP_PINNED PR_LOOP_PR PR_LOOP_LOCK_WAIT PR_LOOP_STATE DRY_RUN \
  PR_LOOP_COMPOSER_INSTALL PR_LOOP_COMPOSER_DIRS PR_LOOP_COMPOSER_BIN

SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; [ $# -lt 2 ] || printf '         %s\n' "${@:2}"; }
expect() { # name condition-command...
  local name="$1"; shift
  if "$@"; then ok "$name"; else no "$name" "condition failed: $*"; fi
}
same() { # name got want
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "wanted: $3" "got:    $2"; fi
}
has() { [[ "$1" == *"$2"* ]]; }
lacks() { [[ "$1" != *"$2"* ]]; }

# Each call appends "<args>" to $CALLS. FAKE_FAIL_IN=<dir suffix> makes the install in that
# directory fail with exit 3 and an error line, as a missing PHP extension does. FAKE_SLEEP=<s>
# makes every install hang that long first, as one behind a dead mirror does.
COMPOSER="$TMP/fake-composer"
CALLS="$TMP/composer-calls"; export CALLS
cat > "$COMPOSER" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
if [ -n "${FAKE_SLEEP:-}" ]; then echo "Downloading from a mirror that never answers"; sleep "$FAKE_SLEEP"; fi
wd=""
for a in "$@"; do case "$a" in --working-dir=*) wd="${a#--working-dir=}" ;; esac; done
if [ -n "${FAKE_FAIL_IN:-}" ] && [[ "$wd" == *"/$FAKE_FAIL_IN" ]]; then
  echo "Installing dependencies from lock file (including require-dev)"
  echo "Your lock file does not contain a compatible set of packages."
  echo "  Problem 1"
  echo "    - Error: the requested PHP extension gd is missing from your system."
  exit 3
fi
echo "Installing dependencies from lock file (including require-dev)"
echo "Generating optimized autoload files"
SH
chmod +x "$COMPOSER"

# ================================================================ install_composer_deps()
echo "install_composer_deps"
# A file rather than bash -c, as in verify-resolve.sh: splicing function bodies through nested
# quoting tests the quoting, not the function.
{
  echo 'set -uo pipefail'
  echo 'MODE=review; REPO=o/r'
  echo "LOG=$TMP/loop.log"
  sed -n '/^log() /p' "$LOOP"
  sed -n '/^text_excerpt()/,/^}/p' "$LOOP"
  sed -n '/^install_composer_deps()/,/^}/p' "$LOOP"
  echo 'install_composer_deps "$1"; rc=$?'
  echo 'printf "%s" "$COMPOSER_WHY" > "$2.why"'
  echo 'printf "%s" "$COMPOSER_EXCERPT" > "$2.excerpt"'
  echo 'exit "$rc"'
} > "$TMP/driver.sh"
expect "the driver lifted install_composer_deps out of pr-loop.sh" grep -q '^install_composer_deps()' "$TMP/driver.sh"

WT="$TMP/wt"
fresh() { # lock-dirs... -> a worktree with a composer.lock in each named dir ("." for the root)
  local d
  rm -rf "$WT"; mkdir -p "$WT"; echo readme > "$WT/README.md"; echo 'gitdir: x' > "$WT/.git"
  for d in "$@"; do mkdir -p "$WT/$d"; echo '{}' > "$WT/$d/composer.lock"; done
  : > "$CALLS"; : > "$TMP/loop.log"
}
RC=0
deps() { # [env...] -> RC, WHY, EXCERPT, NCALLS
  env PR_LOOP_COMPOSER_BIN="$COMPOSER" "$@" bash "$TMP/driver.sh" "$WT" "$TMP/res" 2>/dev/null
  RC=$?
  WHY="$(cat "$TMP/res.why")"; EXCERPT="$(cat "$TMP/res.excerpt")"
  NCALLS="$(wc -l < "$CALLS")"
}
want_call() { printf 'install --no-interaction --no-progress --no-scripts --no-plugins --working-dir=%s' "$1"; }

fresh
deps
expect "no composer.lock: success" [ "$RC" -eq 0 ]
same "  ... composer is never called" "$NCALLS" 0
expect "  ... and nothing is logged" [ ! -s "$TMP/loop.log" ]

fresh
deps PR_LOOP_COMPOSER_BIN="$TMP/nowhere/composer"
expect "no composer.lock and no composer: still success" [ "$RC" -eq 0 ]

fresh apps/game
deps
expect "apps/game/composer.lock: success" [ "$RC" -eq 0 ]
same "  ... composer called once, in apps/game, non-interactive" "$(cat "$CALLS")" "$(want_call "$WT/apps/game")"
expect "  ... the log names the dir" grep -q 'composer install in apps/game' "$TMP/loop.log"
expect "  ... and carries composer's output" grep -q '    | Generating optimized autoload files' "$TMP/loop.log"
expect "  ... with scripts and plugins off by default" eval \
  'grep -q -- " --no-scripts " "$CALLS" && grep -q -- " --no-plugins " "$CALLS"'
fresh apps/game
deps PR_LOOP_COMPOSER_ALLOW_SCRIPTS=1
same "PR_LOOP_COMPOSER_ALLOW_SCRIPTS=1: installed without --no-scripts --no-plugins" "$(cat "$CALLS")" \
  "install --no-interaction --no-progress --working-dir=$WT/apps/game"

fresh vendor/acme/lib node_modules/pkg apps/game/vendor/acme/lib apps/game/node_modules/pkg
deps
expect "locks only under vendor/ and node_modules/: success" [ "$RC" -eq 0 ]
same "  ... and composer is never called" "$NCALLS" 0
fresh apps/game apps/game/vendor/acme/lib node_modules/pkg
deps
same "  ... beside a real lock, only the real one is installed" "$(cat "$CALLS")" "$(want_call "$WT/apps/game")"

fresh . apps/game packages/lib
deps
expect "three lock dirs: success" [ "$RC" -eq 0 ]
same "  ... each installed once, in a stable order" "$(cat "$CALLS")" \
  "$(want_call "$WT"; echo; want_call "$WT/apps/game"; echo; want_call "$WT/packages/lib")"

fresh apps/game
deps FAKE_FAIL_IN=apps/game
expect "failing composer: non-zero" [ "$RC" -ne 0 ]
same "  ... the reason names the dir and composer's exit code" "$WHY" "composer install failed in apps/game (exit 3)"
expect "  ... the excerpt quotes composer's error" has "$EXCERPT" "PHP extension gd is missing"
expect "  ... and the log has composer's output" grep -q 'PHP extension gd is missing' "$TMP/loop.log"
fresh . apps/game packages/lib
deps FAKE_FAIL_IN=apps/game
same "  ... the first failure stops the rest" "$NCALLS" 2
expect "  ... and the reason names the failing dir, not the last" has "$WHY" "failed in apps/game"

fresh apps/game
start=$(date +%s); deps FAKE_SLEEP=30 PR_LOOP_COMPOSER_TIMEOUT=1; took=$(( $(date +%s) - start ))
expect "hung composer: non-zero" [ "$RC" -ne 0 ]
same "  ... the reason says it timed out, after how long, and where" "$WHY" "composer install timed out after 1s in apps/game"
expect "  ... killed at the timeout, not left to finish" [ "$took" -lt 10 ]

fresh apps/game
deps PR_LOOP_COMPOSER_INSTALL=0
expect "PR_LOOP_COMPOSER_INSTALL=0: success" [ "$RC" -eq 0 ]
same "  ... and composer is never called" "$NCALLS" 0

fresh apps/game packages/lib
deps PR_LOOP_COMPOSER_DIRS="packages/lib"
expect "PR_LOOP_COMPOSER_DIRS: success" [ "$RC" -eq 0 ]
same "  ... only the listed dir is installed" "$(cat "$CALLS")" "$(want_call "$WT/packages/lib")"
fresh . apps/game
deps PR_LOOP_COMPOSER_DIRS=" apps/game/  . "
same "  ... several dirs, in the order listed, slashes and spaces tolerated" "$(cat "$CALLS")" \
  "$(want_call "$WT/apps/game"; echo; want_call "$WT/.")"
fresh apps/game
deps PR_LOOP_COMPOSER_DIRS="apps/game apps/missing"
expect "  ... a listed dir with no composer.lock fails" [ "$RC" -ne 0 ]
expect "  ... naming that dir" has "$WHY" "apps/missing"
same "  ... before anything is installed" "$NCALLS" 0
fresh apps/game
deps PR_LOOP_COMPOSER_DIRS='*'
expect "  ... a listed dir is never globbed" eval '[ "$RC" -ne 0 ] && has "$WHY" "names *,"'
# Both refused paths below do hold a composer.lock, so only the path rule can stop them.
fresh apps/game
deps PR_LOOP_COMPOSER_DIRS="$WT/apps/game"
expect "  ... an absolute dir is refused" eval '[ "$RC" -ne 0 ] && has "$WHY" "is absolute"'
same "  ... and nothing is installed" "$NCALLS" 0
fresh apps/game
mkdir -p "$TMP/outside"; echo '{}' > "$TMP/outside/composer.lock"
deps PR_LOOP_COMPOSER_DIRS="apps/../../outside"
expect "  ... a dir with a .. component is refused" eval '[ "$RC" -ne 0 ] && has "$WHY" "has a .. component"'
same "  ... and nothing is installed" "$NCALLS" 0
deps PR_LOOP_COMPOSER_DIRS="apps/game/.."
expect "  ... even a trailing .. that stays inside the worktree" eval '[ "$RC" -ne 0 ] && has "$WHY" "has a .. component"'

fresh apps/game
deps PR_LOOP_COMPOSER_BIN="$TMP/nowhere/composer"
expect "composer.lock but no composer: failure" [ "$RC" -ne 0 ]
expect "  ... saying composer is missing and where it was needed" eval \
  'has "$WHY" "$TMP/nowhere/composer is not on PATH" && has "$WHY" "apps/game/composer.lock"'

# ================================================================ finish() and an installed vendor/
# The real finish() against a real git repo, before the whole-tick stubs put a fake git on PATH:
# a worktree holding an untracked vendor/ (what an install leaves when the repo does not ignore
# it) must still be removed.
echo
echo "finish"
REPO_DIR="$TMP/repo"; FWT="$TMP/fwt"
if ! command -v git >/dev/null 2>&1; then
  no "finish removes a worktree with an untracked vendor/" "git is not on PATH, so this case cannot run"
else
  git init -q "$REPO_DIR"
  git -C "$REPO_DIR" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m init
  git -C "$REPO_DIR" worktree add -q --detach "$FWT" HEAD
  mkdir -p "$FWT/vendor/acme"; echo '<?php' > "$FWT/vendor/acme/autoload.php"
  expect "a plain worktree remove refuses that worktree (so the case means something)" eval \
    '! git -C "$REPO_DIR" worktree remove "$FWT" >/dev/null 2>&1 && [ -d "$FWT" ]'
  {
    echo 'set -uo pipefail'
    echo 'MODE=review; REPO=o/r; CLAIM=review:in-progress; OK=review:findings; CLEAN=review:clean'
    echo 'FAIL=review:needs-human; TRIGGER=review:requested; CONTEXT_FILE=.pr-loop-context.md'
    echo "LOG=$TMP/finish.log; STATE=$TMP/fstate; MAIN=$REPO_DIR"
    echo 'declare -A W_SESS=() W_WT=() W_SHA=() W_HEADREF=() W_BASE=() W_PROV=() W_PID=() W_START=() W_STALLS=() W_BLOCKS=()'
    echo 'relabel() { :; }; comment() { :; }; stop_agy() { :; }'
    sed -n '/^log() /p' "$LOOP"
    sed -n '/^finish()/,/^}/p' "$LOOP"
    echo "W_WT[7]=$FWT; W_PROV[7]=composer"
    echo 'finish 7 fail "composer install failed in . (exit 3)"'
  } > "$TMP/finish-driver.sh"
  mkdir -p "$TMP/fstate"
  bash "$TMP/finish-driver.sh" 2>/dev/null
  expect "finish removes a worktree with an untracked vendor/" [ ! -e "$FWT" ]
  expect "  ... and does not log it as kept" eval '! grep -q "kept" "$TMP/finish.log"'
fi

# ================================================================ whole ticks
echo
echo "pr-loop.sh composer step"
LC="$TMP/common"; mkdir -p "$LC/prompts"
for f in pr-loop.sh classify-pane.sh provider-fallback.py marker.py \
         prompts/review.txt prompts/resolve.txt prompts/review.agy.txt; do
  cp "$ROOT/$f" "$LC/$f"
done
DB="$TMP/db.json"; export DB
cat > "$LC/gitea-pr.py" <<'PY'
import json, os, sys
db = json.load(open(os.environ["DB"]))
cmd, a = sys.argv[1], dict(zip(sys.argv[2::2], sys.argv[3::2]))
pr = db["pr"]
if cmd == "list":
    print(json.dumps([pr]))
elif cmd == "head":
    print(pr["head_sha"])
elif cmd == "comments":
    print(json.dumps([{"id": i, "user": "bot", "created_at": "", "body": b} for i, b in enumerate(db["comments"])]))
elif cmd == "comment":
    db["comments"].append(open(a["--body-file"]).read())
elif cmd == "label":
    pr["labels"] = [l for l in pr["labels"] if l != a.get("--remove")] + [a["--add"]]
json.dump(db, open(os.environ["DB"], "w"))
PY

# The tmux stub records every call (a new session also in $CALLS, to order it against composer)
# and, once pasted into, shows "working" twice and then a finished, marker-less review, so a tick
# that does start a worker ends quickly.
TMUXD="$TMP/tmux"; export TMUXD
cat > "$BIN/tmux" <<'SH'
#!/usr/bin/env bash
cmd="$1"; shift
t=""; prev=""
for a in "$@"; do case "$prev" in -t|-s) t="$a" ;; esac; prev="$a"; done
echo "$cmd $*" >> "$TMUXD/calls"
[ "$cmd" = new-session ] && echo "tmux new-session" >> "$CALLS"
case "$cmd" in
  new-session) : > "$TMUXD/sess-$t"; echo 0 > "$TMUXD/n-$t"; echo pre > "$TMUXD/phase-$t" ;;
  has-session) [ -f "$TMUXD/sess-$t" ]; exit ;;
  kill-session) rm -f "$TMUXD/sess-$t" ;;
  paste-buffer) echo post > "$TMUXD/phase-$t" ;;
  capture-pane)
    [ -f "$TMUXD/sess-$t" ] || exit 1
    if [ "$(cat "$TMUXD/phase-$t")" = pre ]; then echo '❯ '; exit 0; fi
    n="$(cat "$TMUXD/n-$t")"; echo $((n + 1)) > "$TMUXD/n-$t"
    if [ "$n" -lt 2 ]; then echo '✻ Reviewing… (esc to interrupt)'; else printf 'PR_REVIEW_DONE\n> \n'; fi ;;
esac
exit 0
SH
# `worktree add` seeds the new worktree with a composer.lock in each of $WT_SEED's dirs.
cat > "$BIN/git" <<'SH'
#!/usr/bin/env bash
[ "$1" = -C ] && shift 2
case "$1 ${2:-}" in
  "worktree add")
    wt="${@: -2:1}"; mkdir -p "$wt"
    for d in ${WT_SEED:-}; do mkdir -p "$wt/$d"; echo '{}' > "$wt/$d/composer.lock"; done ;;
  "worktree remove") rm -rf "${@: -1}" ;;
esac
exit 0
SH
for t in claude tea agy; do printf '#!/bin/sh\nexit 0\n' > "$BIN/$t"; done
chmod +x "$BIN"/*
mkdir -p "$TMP/main/.git"
ST="$TMP/state"

reset() {
  python3 - "$DB" <<'PY'
import json, sys
json.dump({"pr": {"number": 7, "title": "t", "draft": False, "head_sha": "a" * 40, "head_ref": "feature/x",
                  "base_ref": "develop", "author": "craig", "is_bot": False, "labels": ["review:requested"],
                  "url": ""}, "comments": []}, open(sys.argv[1], "w"))
PY
  rm -rf "$TMUXD" "$TMP/wt-loop" "$ST"; mkdir -p "$TMUXD"; : > "$TMUXD/calls"; : > "$CALLS"
}
loop() { # [env...] -> $TMP/out.txt
  env "$@" PR_LOOP_STATE="$ST" PR_LOOP_MAIN="$TMP/main" PR_LOOP_WORKTREES="$TMP/wt-loop" PR_LOOP_REPO=o/r \
    PR_LOOP_POOL=0 PR_LOOP_COMPOSER_BIN="$COMPOSER" SKIP_BUSY_GUARD=1 MIN_FREE_GB=0 POLL=0.2 \
    timeout 120 bash "$LC/pr-loop.sh" review > "$TMP/out.txt" 2>&1
}
labels() { python3 -c 'import json,os; print(",".join(json.load(open(os.environ["DB"]))["pr"]["labels"]))'; }
comments() { python3 -c 'import json,os; print("\n----\n".join(json.load(open(os.environ["DB"]))["comments"]))'; }
log_() { cat "$TMP/out.txt"; }

reset
loop WT_SEED=apps/game FAKE_FAIL_IN=apps/game
same "install fails: the PR goes to review:needs-human" "$(labels)" "review:needs-human"
expect "  ... the comment gives the reason" has "$(comments)" "composer install failed in apps/game (exit 3)"
expect "  ... and quotes composer" eval 'has "$(comments)" "composer said:" && has "$(comments)" "PHP extension gd is missing"'
expect "  ... no worker is started" eval '! grep -q "^new-session" "$TMUXD/calls"'
expect "  ... no session is killed, empty or otherwise" eval '! grep -q "^kill-session" "$TMUXD/calls"'
expect "  ... the worktree is removed" [ ! -e "$TMP/wt-loop/prloop-review-7" ]
expect "  ... the log says why and that no worker ran" has "$(log_)" "#7: composer install failed in apps/game (exit 3); not starting a worker"
expect "  ... the tick ends normally" eval 'has "$(log_)" "no worker started" && lacks "$(log_)" "unbound variable"'

reset
loop WT_SEED=apps/game
same "install succeeds: composer runs before the worker starts" "$(cut -d' ' -f1-2 "$CALLS")" \
  "$(printf 'install --no-interaction\ntmux new-session')"
expect "  ... in the PR worktree" grep -q -- "--working-dir=$TMP/wt-loop/prloop-review-7/apps/game\$" "$CALLS"

reset
loop WT_SEED=apps/game PR_LOOP_COMPOSER_INSTALL=0
same "PR_LOOP_COMPOSER_INSTALL=0: the worker starts with no install" "$(cat "$CALLS")" "tmux new-session"

expect "the user's real HOME was never used" [ ! -e "$HOME/.claude.json" ]

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
