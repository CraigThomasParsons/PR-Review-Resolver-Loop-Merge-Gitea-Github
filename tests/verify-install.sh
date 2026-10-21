#!/usr/bin/env bash
# Offline cases for install.sh: copy deploy from git, drift refusal, lock-guarded swap, rollback,
# and the master/clean-tree guards. Builds a throwaway git repository from this working tree
# (tracked files plus new untracked ones, so uncommitted edits to install.sh are what gets
# tested) and installs into a temporary home with --no-systemctl. Touches nothing outside $TMP.
set -uo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
BG=()
trap 'for p in "${BG[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$TMP"' EXIT
export HOME="$TMP/userhome"; mkdir -p "$HOME"
H="$TMP/target"; mkdir -p "$H"
R="$TMP/repo"; mkdir -p "$R"

(cd "$SRC" && git ls-files -co --exclude-standard -z | tar --null -T - -cf -) | tar -xf - -C "$R"
g() { git -C "$R" -c user.name=verify -c user.email=verify@localhost -c commit.gpgsign=false "$@"; }
g init -q -b master
g add -A
g commit -q -m C1
C1="$(g rev-parse HEAD)"

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; [ $# -lt 2 ] || printf '         %s\n' "${@:2}"; }
expect() { local name="$1"; shift; if "$@"; then ok "$name"; else no "$name" "condition failed: $*"; fi; }
has() { [[ "$1" == *"$2"* ]]; }

inst() { bash "$R/install.sh" --target-home "$H" --no-systemctl "$@" 2>&1; }
SK="$H/.claude/skills"
LIVE="$SK/pr-loops-common"
deployed_commit() { sed -n 's/^commit //p' "$1/.deployed-from" 2>/dev/null; }

hold_lock() { # file seconds
  mkdir -p "$(dirname "$1")"
  flock "$1" sleep "$2" & BG+=($!)
  local i
  for i in $(seq 1 50); do flock -n "$1" true 2>/dev/null || return 0; sleep 0.1; done
}

echo "install.sh"

out="$(bash "$R/install.sh" --bogus 2>&1)"; rc=$?
expect "unknown argument exits 2"        [ "$rc" = 2 ]
out="$(bash "$R/install.sh" --target-home "$H" 2>&1)"; rc=$?
expect "--target-home without --no-systemctl exits 2" [ "$rc" = 2 ]
out="$(inst --rollback)"; rc=$?
expect "rollback with nothing to roll back is refused" [ "$rc" = 1 ]

out="$(inst --list)"; rc=$?
expect "--list exits 0"                  [ "$rc" = 0 ]
expect "--list says what it would deploy" has "$out" "skill pr-loops-common: new"
expect "--list changes nothing"          eval '[ ! -e "$H/.claude" ] && [ ! -e "$H/.local" ]'

mkdir -p "$R/skills/pr-loops-common/__pycache__"
touch "$R/skills/pr-loops-common/__pycache__/x.pyc" "$R/skills/pr-loops-common/untracked.bak"
out="$(inst)"; rc=$?
expect "first deploy exits 0"            [ "$rc" = 0 ]
for d in "$R"/skills/*/; do
  name="$(basename "$d")"
  expect "skill $name deployed as a real directory" [ -d "$SK/$name" ] && [ ! -L "$SK/$name" ]
done
expect "pr-loop.sh matches the commit"   cmp -s "$LIVE/pr-loop.sh" "$R/skills/pr-loops-common/pr-loop.sh"
expect ".deployed-from names the commit" [ "$(deployed_commit "$LIVE")" = "$C1" ]
expect "untracked files are not deployed" eval '[ ! -e "$LIVE/untracked.bak" ] && [ ! -e "$LIVE/__pycache__" ]'
expect "pr-trigger installed executable" [ -x "$H/.local/bin/pr-trigger" ]
expect "pr-drain installed executable"   [ -x "$H/.local/bin/pr-drain" ]
expect "pr-trigger is the committed script" cmp -s "$H/.local/bin/pr-trigger" "$R/skills/pr-loops-common/pr-trigger.sh"
expect "path unit installed"             [ -f "$H/.config/systemd/user/pr-trigger-drain.path" ]
expect "service unit installed"          [ -f "$H/.config/systemd/user/pr-trigger-drain.service" ]
expect "no staging leftovers"            [ -z "$(find "$SK" "$H/.local/bin" -maxdepth 1 -name '.*.new')" ]
qout="$(PR_LOOP_STATE="$TMP/qs" "$H/.local/bin/pr-trigger" --repo o/r --pr 1 --sha "$C1" --event opened)"; rc=$?
expect "the installed pr-trigger works"  eval '[ "$rc" = 0 ] && has "$qout" "queued: o/r#1"'
rm -rf "$R/skills/pr-loops-common/__pycache__" "$R/skills/pr-loops-common/untracked.bak"

out="$(inst)"; rc=$?
expect "redeploying the same commit exits 0" [ "$rc" = 0 ]
expect "the previous copy is kept as .prev" eval '[ -d "$SK/.pr-loops-common.prev" ] && [ -f "$H/.local/bin/.pr-trigger.prev" ]'

echo "# hand edit" >> "$LIVE/pr-loop.sh"
touch "$LIVE/stray.sh"
out="$(inst)"; rc=$?
expect "a hand-edited live copy is refused" [ "$rc" = 1 ]
expect "  ... naming the changed file"   has "$out" "changed in live copy: pr-loop.sh"
expect "  ... and the extra file"        has "$out" "only in live copy: stray.sh"
expect "  ... leaving the edit in place" grep -q '# hand edit' "$LIVE/pr-loop.sh"
out="$(inst --list)"; rc=$?
expect "--list with drift exits 0 and warns" eval '[ "$rc" = 0 ] && has "$out" "would refuse without --force"'
out="$(inst --force)"; rc=$?
expect "--force deploys over drift"      eval '[ "$rc" = 0 ] && cmp -s "$LIVE/pr-loop.sh" "$R/skills/pr-loops-common/pr-loop.sh"'
expect "  ... and drops the stray file"  [ ! -e "$LIVE/stray.sh" ]

mkdir -p "$LIVE/__pycache__"; touch "$LIVE/__pycache__/gitea-pr.cpython-314.pyc"
out="$(inst)"; rc=$?
expect "__pycache__ in the live copy is not drift" [ "$rc" = 0 ]

echo "v2" >> "$R/skills/pr-loops-common/README.md"
echo "# v2" >> "$R/skills/pr-loops-common/pr-trigger.sh"
g commit -q -am C2
C2="$(g rev-parse HEAD)"
out="$(inst)"; rc=$?
expect "a new commit deploys over a copy that matches its .deployed-from" [ "$rc" = 0 ]
expect "  ... with the new content"      grep -q '^v2$' "$LIVE/README.md"
expect "  ... and the new pr-trigger"    grep -q '^# v2$' "$H/.local/bin/pr-trigger"
expect "  ... stamped with the new commit" [ "$(deployed_commit "$LIVE")" = "$C2" ]

out="$(inst --rollback)"; rc=$?
expect "--rollback exits 0"              [ "$rc" = 0 ]
expect "  ... restores the previous skills copy" eval '[ "$(deployed_commit "$LIVE")" = "$C1" ] && ! grep -q '\''^v2$'\'' "$LIVE/README.md"'
expect "  ... and the previous pr-trigger" eval '! grep -q '\''^# v2$'\'' "$H/.local/bin/pr-trigger"'
out="$(inst --rollback)"; rc=$?
expect "a second --rollback rolls forward again" eval '[ "$rc" = 0 ] && [ "$(deployed_commit "$LIVE")" = "$C2" ]'

before="$(cat "$LIVE/.deployed-from")"
hold_lock "$H/.local/state/gitea-pr-loops/review.lock" 4
out="$(inst --lock-wait 1)"; rc=$?
expect "a held review.lock past --lock-wait fails with exit 3" eval '[ "$rc" = 3 ] && has "$out" "timed out waiting"'
expect "  ... changing nothing"          [ "$(cat "$LIVE/.deployed-from")" = "$before" ]
expect "  ... and leaving no staging dirs" [ -z "$(find "$SK" "$H/.local/bin" "$H/.config/systemd/user" -maxdepth 1 -name '.*.new')" ]
wait "${BG[@]}" 2>/dev/null
hold_lock "$H/.local/state/gitea-pr-loops/drain.lock" 2
start=$(date +%s)
out="$(inst --lock-wait 20)"; rc=$?
waited=$(( $(date +%s) - start ))
expect "a held drain.lock delays the swap until it is released" eval '[ "$rc" = 0 ] && [ "$waited" -ge 1 ] && [ "$waited" -lt 15 ]'
expect "  ... saying it is waiting"      has "$out" "waiting up to"

echo "dirty" >> "$R/README.md"
out="$(inst)"; rc=$?
expect "a dirty tree is refused"         eval '[ "$rc" = 1 ] && has "$out" "uncommitted changes"'
out="$(inst --allow-dirty)"; rc=$?
expect "--allow-dirty deploys anyway"    [ "$rc" = 0 ]
g checkout -q -- README.md

g checkout -q -b feature/x
echo "v3" >> "$R/skills/pr-loops-common/README.md"
g commit -q -am C3
C3="$(g rev-parse HEAD)"
out="$(inst)"; rc=$?
expect "a HEAD that is not master is refused" eval '[ "$rc" = 1 ] && has "$out" "not master"'
out="$(inst --ref feature/x)"; rc=$?
expect "--ref deploys it deliberately"   eval '[ "$rc" = 0 ] && [ "$(deployed_commit "$LIVE")" = "$C3" ]'
g checkout -q master

rm -rf "$SK/pr-merge-loop"; ln -s "$R/skills/pr-merge-loop" "$SK/pr-merge-loop"
out="$(inst)"; rc=$?
expect "a symlinked development install is refused" eval '[ "$rc" = 1 ] && has "$out" "symlink"'
out="$(inst --force)"; rc=$?
expect "  ... and replaced by a copy with --force" eval '[ "$rc" = 0 ] && [ -d "$SK/pr-merge-loop" ] && [ ! -L "$SK/pr-merge-loop" ]'

rm -f "$LIVE/.deployed-from" "$LIVE/README.md"
out="$(inst)"; rc=$?
expect "an unstamped copy missing a file the commit adds is not drift" [ "$rc" = 0 ]
rm -f "$LIVE/.deployed-from"; echo "# edit" >> "$LIVE/marker.py"
out="$(inst)"; rc=$?
expect "an unstamped copy with an edit is drift" eval '[ "$rc" = 1 ] && has "$out" "changed in live copy: marker.py"'

expect "the user's own HOME was never touched" [ -z "$(ls -A "$HOME")" ]

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
