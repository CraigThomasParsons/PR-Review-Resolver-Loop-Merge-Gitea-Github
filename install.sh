#!/usr/bin/env bash
# install.sh — deploy this repo to the machine that runs the PR loop.
#
# Production is a COPY of a committed revision, not a symlink to this checkout: this checkout is
# also where development happens, and the hourly timer, the 15-minute merge tick and every PR
# event would otherwise run whatever happens to be checked out (pr-loop.sh pins itself to a
# private copy for the same reason). install_skills_and_actions.sh remains the opt-in symlink
# installer for development.
#
# What it deploys, from `git archive <ref>` (tracked files only; no .bak noise, no __pycache__):
#   skills/<name>/                     -> ~/.claude/skills/<name>/  (+ .deployed-from)
#   skills/pr-loops-common/pr-trigger.sh -> ~/.local/bin/pr-trigger
#   skills/pr-loops-common/pr-drain.sh   -> ~/.local/bin/pr-drain
#   systemd/pr-trigger-drain.{path,service} -> ~/.config/systemd/user/
# then `systemctl --user daemon-reload` and `enable --now pr-trigger-drain.path`.
#
# Safety:
#   * Refuses a dirty tree, or a HEAD that is not master/origin/master, unless --allow-dirty or
#     an explicit --ref.
#   * Drift check: a live skills copy that differs from the revision it was deployed from (its
#     .deployed-from), i.e. hand edits on the box, makes it refuse unless --force. A copy with no
#     .deployed-from is compared with the revision being deployed; files that revision adds are
#     not drift.
#   * The swap holds review.lock, resolve.lock, merge.lock and drain.lock (in
#     ~/.local/state/gitea-pr-loops) so no tick or drain is mid-run, stages each new copy beside
#     the live one, and exchanges them atomically. The previous copy is kept as .<name>.prev (one
#     generation), and installed files as .<file>.prev.
#
# Usage:
#   install.sh [--ref REF] [--allow-dirty] [--force] [--lock-wait SECONDS]
#              [--list] [--no-systemctl] [--target-home DIR]
#   install.sh --rollback [--list] [--no-systemctl] [--target-home DIR] [--lock-wait SECONDS]
#
#   --ref REF          deploy REF instead of HEAD (skips the master and clean-tree checks)
#   --allow-dirty      deploy HEAD even though the working tree has uncommitted changes
#   --force            deploy over drifted (hand-edited) or symlinked live copies
#   --rollback         swap every .prev back into place (running it again rolls forward)
#   --lock-wait S      total seconds to wait for the loop locks (default 600)
#   --list             print what would happen; change nothing
#   --no-systemctl     skip daemon-reload and enable (tests, or a box without a user manager)
#   --target-home DIR  install under DIR instead of $HOME (requires --no-systemctl)
#
# Exit codes: 0 done, 1 refused (dirty, not master, drift, nothing to roll back), 2 bad
#             arguments, 3 failure (lock timeout, write error, systemctl error).

set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

ref="" allow_dirty=0 force=0 rollback=0 list_only=0 no_systemctl=0 lock_wait=600
target_home="${HOME:-}"
target_home_given=0

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }
say() { printf '%s\n' "$*"; }
refuse() { printf 'install.sh: refused: %s\n' "$*" >&2; exit 1; }
badarg() { printf 'install.sh: %s\n' "$*" >&2; exit 2; }
fail() { printf 'install.sh: FAILED: %s\n' "$*" >&2; exit 3; }

while (($#)); do
  case "$1" in
    --ref) [ $# -ge 2 ] || badarg "--ref needs a value"; ref="$2"; shift 2 ;;
    --allow-dirty) allow_dirty=1; shift ;;
    --force) force=1; shift ;;
    --rollback) rollback=1; shift ;;
    --lock-wait) [ $# -ge 2 ] || badarg "--lock-wait needs a value"; lock_wait="$2"; shift 2 ;;
    --list) list_only=1; shift ;;
    --no-systemctl) no_systemctl=1; shift ;;
    --target-home) [ $# -ge 2 ] || badarg "--target-home needs a directory"; target_home="$2"; target_home_given=1; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) badarg "unknown argument: $1" ;;
  esac
done

[[ "$lock_wait" =~ ^[0-9]+$ ]] || badarg "--lock-wait must be whole seconds"
[ -n "$target_home" ] || badarg "HOME is not set; pass --target-home"
[ -d "$target_home" ] || badarg "target home $target_home does not exist"
target_home="$(cd -- "$target_home" && pwd)"
if [ "$target_home_given" = 1 ] && [ "$no_systemctl" = 0 ] && [ "$target_home" != "$(cd -- "${HOME:-/}" && pwd)" ]; then
  badarg "--target-home other than \$HOME needs --no-systemctl (systemctl --user would act on this user)"
fi
[ "$rollback" = 1 ] && [ -n "$ref" ] && badarg "--rollback takes no --ref"

SKILLS_DIR="$target_home/.claude/skills"
BIN_DIR="$target_home/.local/bin"
UNIT_DIR="$target_home/.config/systemd/user"
STATE="$target_home/.local/state/gitea-pr-loops"
# installed name : path in the archive
BIN_FILES=("pr-trigger:skills/pr-loops-common/pr-trigger.sh" "pr-drain:skills/pr-loops-common/pr-drain.sh")
UNITS=(pr-trigger-drain.path pr-trigger-drain.service)
LOCKS=(review resolve merge drain)

git_() { git -C "$REPO_ROOT" "$@"; }

work=""
staged=()
cleanup() {
  local p
  for p in "${staged[@]}"; do rm -rf -- "$p"; done
  [ -n "$work" ] && rm -rf -- "$work"
}
trap cleanup EXIT

take_locks() {
  [ -d "$STATE" ] || mkdir -p "$STATE" || fail "cannot create $STATE"
  local deadline=$(( $(date +%s) + lock_wait )) name fd left
  for name in "${LOCKS[@]}"; do
    exec {fd}>"$STATE/$name.lock" || fail "cannot open $STATE/$name.lock"
    if ! flock -n "$fd"; then
      left=$(( deadline - $(date +%s) )); [ "$left" -gt 0 ] || left=0
      say "waiting up to ${left}s for $name.lock (a tick or drain is running)"
      flock -w "$left" "$fd" || fail "timed out waiting for $STATE/$name.lock; nothing was changed"
    fi
  done
}

HAVE_EXCHANGE=0
mv --help 2>/dev/null | grep -q -- '--exchange' && HAVE_EXCHANGE=1

# Put $new at $dest; the previous $dest (if any) ends up at $prev. $new must not exist afterwards.
swap_in() { # new dest prev
  local new="$1" dest="$2" prev="$3"
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    if [ "$HAVE_EXCHANGE" = 1 ] && mv --exchange --no-target-directory -- "$new" "$dest" 2>/dev/null; then
      rm -rf -- "$prev" && mv --no-target-directory -- "$new" "$prev"
    else
      rm -rf -- "$prev" && mv --no-target-directory -- "$dest" "$prev" && mv --no-target-directory -- "$new" "$dest"
    fi
  else
    rm -rf -- "$prev" && mv --no-target-directory -- "$new" "$dest"
  fi
}

tree_files() { # dir -> sorted relative paths, ignoring bytecode and the deploy stamp
  (cd -- "$1" && find . -name __pycache__ -prune -o \( -type f -o -type l \) ! -name '*.pyc' ! -path ./.deployed-from -print) \
    | sed 's|^\./||' | LC_ALL=C sort
}

drift_report() { # live baseline additions_ok -> one line per drifted path
  local live="$1" base="$2" additions_ok="$3" f
  LC_ALL=C comm -23 <(tree_files "$live") <(tree_files "$base") | sed 's/^/only in live copy: /'
  if [ "$additions_ok" = 0 ]; then
    LC_ALL=C comm -13 <(tree_files "$live") <(tree_files "$base") | sed 's/^/missing from live copy: /'
  fi
  LC_ALL=C comm -12 <(tree_files "$live") <(tree_files "$base") | while IFS= read -r f; do
    cmp -s -- "$live/$f" "$base/$f" || printf 'changed in live copy: %s\n' "$f"
  done
}

managed_files() { # "dest" lines for every installed single file
  local entry
  for entry in "${BIN_FILES[@]}"; do printf '%s\n' "$BIN_DIR/${entry%%:*}"; done
  for entry in "${UNITS[@]}"; do printf '%s\n' "$UNIT_DIR/$entry"; done
}
prev_of() { printf '%s/.%s.prev\n' "$(dirname -- "$1")" "$(basename -- "$1")"; }

run_systemctl() {
  if [ "$no_systemctl" = 1 ]; then say "systemctl: skipped (--no-systemctl)"; return 0; fi
  systemctl --user daemon-reload || fail "systemctl --user daemon-reload failed"
  if [ "$rollback" = 0 ]; then
    systemctl --user enable --now pr-trigger-drain.path || fail "systemctl --user enable --now pr-trigger-drain.path failed"
    say "systemctl: daemon-reload, enabled and started pr-trigger-drain.path"
  else
    say "systemctl: daemon-reload"
  fi
}

# ---------------------------------------------------------------- rollback
if [ "$rollback" = 1 ]; then
  todo=()
  for d in "$REPO_ROOT"/skills/*/; do
    name="$(basename "$d")"
    [ -e "$SKILLS_DIR/.$name.prev" ] || [ -L "$SKILLS_DIR/.$name.prev" ] && todo+=("$SKILLS_DIR/$name")
  done
  while IFS= read -r f; do [ -e "$(prev_of "$f")" ] && todo+=("$f"); done < <(managed_files)
  [ "${#todo[@]}" -gt 0 ] || refuse "nothing to roll back under $target_home"
  if [ "$list_only" = 1 ]; then
    for p in "${todo[@]}"; do say "would roll back $p"; done
    exit 0
  fi
  take_locks
  for p in "${todo[@]}"; do
    prev="$(prev_of "$p")"
    tmp="$prev.swap"
    rm -rf -- "$tmp"
    mv --no-target-directory -- "$prev" "$tmp" && swap_in "$tmp" "$p" "$prev" || fail "could not roll back $p"
    say "rolled back $p"
  done
  run_systemctl
  exit 0
fi

# ---------------------------------------------------------------- source revision
git_ rev-parse --git-dir >/dev/null 2>&1 || fail "$REPO_ROOT is not a git checkout"
if [ -z "$ref" ]; then
  ref=HEAD
  head="$(git_ rev-parse HEAD)" || fail "cannot resolve HEAD"
  branch="$(git_ symbolic-ref -q --short HEAD || true)"
  on_master=0
  [ "$branch" = master ] && on_master=1
  for m in master origin/master; do
    [ "$(git_ rev-parse -q --verify "$m^{commit}" 2>/dev/null)" = "$head" ] && on_master=1
  done
  [ "$on_master" = 1 ] || refuse "HEAD (${branch:-detached}) is not master or origin/master; pass --ref to deploy it deliberately"
  if [ "$allow_dirty" = 0 ] && [ -n "$(git_ status --porcelain --untracked-files=no)" ]; then
    refuse "the working tree has uncommitted changes, which would not be deployed; commit them or pass --allow-dirty"
  fi
fi
commit="$(git_ rev-parse -q --verify "$ref^{commit}")" || badarg "cannot resolve --ref $ref"

work="$(mktemp -d)" || fail "mktemp failed"
mkdir -p "$work/new"
git_ archive --format=tar "$commit" -- skills systemd | tar -x -C "$work/new" \
  || fail "git archive of $commit failed (does it predate systemd/?)"
for entry in "${BIN_FILES[@]}"; do
  [ -f "$work/new/${entry#*:}" ] || fail "$commit has no ${entry#*:}"
done
for u in "${UNITS[@]}"; do [ -f "$work/new/systemd/$u" ] || fail "$commit has no systemd/$u"; done

mapfile -t SKILLS < <(cd "$work/new/skills" && find . -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort)
[ "${#SKILLS[@]}" -gt 0 ] || fail "$commit has no skills/"

say "deploying $commit ($ref) from $REPO_ROOT into $target_home"

# ---------------------------------------------------------------- drift check
baseline_tree() { # commit -> extracted tree root (cached)
  local c="$1"
  if [ ! -d "$work/base-$c" ]; then
    mkdir -p "$work/base-$c"
    git_ archive --format=tar "$c" -- skills | tar -x -C "$work/base-$c" || return 1
  fi
  printf '%s\n' "$work/base-$c"
}

drifted=0
for name in "${SKILLS[@]}"; do
  dest="$SKILLS_DIR/$name"
  if [ -L "$dest" ]; then
    say "  skill $name: live entry is a symlink (development install) -> $(readlink "$dest")"
    drifted=1; continue
  fi
  if [ ! -e "$dest" ]; then say "  skill $name: new"; continue; fi
  [ -d "$dest" ] || { say "  skill $name: live entry is not a directory"; drifted=1; continue; }
  base="" additions_ok=1 from=""
  if [ -f "$dest/.deployed-from" ]; then
    from="$(sed -n 's/^commit //p' "$dest/.deployed-from" | head -1)"
    if [ -n "$from" ] && git_ cat-file -e "$from^{commit}" 2>/dev/null && root="$(baseline_tree "$from")"; then
      base="$root/skills/$name"; additions_ok=0
      [ -d "$base" ] || { base="$work/empty"; mkdir -p "$base"; }
    else
      say "  skill $name: deployed from ${from:-an unknown revision} that this checkout does not have; comparing with $commit"
    fi
  fi
  [ -n "$base" ] || base="$work/new/skills/$name"
  report="$(drift_report "$dest" "$base" "$additions_ok")"
  if [ -n "$report" ]; then
    say "  skill $name: DRIFT against ${from:-$commit}:"
    printf '%s\n' "$report" | sed 's/^/      /'
    drifted=1
  elif [ -n "$from" ] && [ "$additions_ok" = 0 ]; then
    say "  skill $name: replace (live copy matches its .deployed-from ${from:0:12})"
  else
    say "  skill $name: replace"
  fi
done
for entry in "${BIN_FILES[@]}"; do say "  bin $BIN_DIR/${entry%%:*} <- ${entry#*:}"; done
for u in "${UNITS[@]}"; do say "  unit $UNIT_DIR/$u"; done
if [ "$no_systemctl" = 1 ]; then say "  systemctl: skipped"; else say "  systemctl --user daemon-reload; enable --now pr-trigger-drain.path"; fi

if [ "$drifted" = 1 ] && [ "$force" = 0 ]; then
  [ "$list_only" = 1 ] && { say "(list only; a real run would refuse without --force)"; exit 0; }
  refuse "live copies differ from what was deployed (see above); review them, then rerun with --force"
fi
[ "$list_only" = 1 ] && exit 0

# ---------------------------------------------------------------- stage
mkdir -p "$SKILLS_DIR" "$BIN_DIR" "$UNIT_DIR" || fail "cannot create target directories"
stamp="$(printf 'commit %s\nref %s\ndeployed_at %s\nsource %s\n' "$commit" "$ref" "$(date -Is)" "$REPO_ROOT")"
for name in "${SKILLS[@]}"; do
  new="$SKILLS_DIR/.$name.new"
  rm -rf -- "$new"; staged+=("$new")
  cp -a -- "$work/new/skills/$name" "$new" || fail "cannot stage $new"
  printf '%s\n' "$stamp" > "$new/.deployed-from" || fail "cannot write $new/.deployed-from"
done
declare -A FILE_SRC=()
for entry in "${BIN_FILES[@]}"; do FILE_SRC["$BIN_DIR/${entry%%:*}"]="$work/new/${entry#*:}"; done
for u in "${UNITS[@]}"; do FILE_SRC["$UNIT_DIR/$u"]="$work/new/systemd/$u"; done
for dest in "${!FILE_SRC[@]}"; do
  new="$(dirname -- "$dest")/.$(basename -- "$dest").new"
  staged+=("$new")
  mode=0644; [[ "$dest" == "$BIN_DIR/"* ]] && mode=0755
  install -m "$mode" -- "${FILE_SRC[$dest]}" "$new" || fail "cannot stage $new"
done

# ---------------------------------------------------------------- swap
take_locks
swapped=()
revert() {
  local p
  for p in "${swapped[@]}"; do
    local prev; prev="$(prev_of "$p")"
    if [ -e "$prev" ] || [ -L "$prev" ]; then
      rm -rf -- "$prev.swap"; mv --no-target-directory -- "$prev" "$prev.swap" && swap_in "$prev.swap" "$p" "$prev"
    else
      rm -rf -- "$p"
    fi
  done
}
for name in "${SKILLS[@]}"; do
  dest="$SKILLS_DIR/$name"
  if ! swap_in "$SKILLS_DIR/.$name.new" "$dest" "$(prev_of "$dest")"; then
    revert; fail "could not swap in $dest; earlier swaps in this run were reverted"
  fi
  swapped+=("$dest")
done
for dest in "${!FILE_SRC[@]}"; do
  new="$(dirname -- "$dest")/.$(basename -- "$dest").new"
  if ! swap_in "$new" "$dest" "$(prev_of "$dest")"; then
    revert; fail "could not install $dest; earlier swaps in this run were reverted"
  fi
  swapped+=("$dest")
done
staged=()

run_systemctl
say "deployed $commit"
