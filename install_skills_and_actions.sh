#!/usr/bin/env bash
# install_skills_and_actions.sh — DEVELOPMENT installer: symlink each
# skills/<name> entry into a consumer's skills directory, so editing a skill in
# this repo takes effect immediately wherever it is linked.
#
# This is not how production is deployed. ~/.claude/skills on the review host
# is a copy of a committed revision, deployed by ./install.sh (which also
# installs pr-trigger, pr-drain and the systemd units). Linking production to
# this checkout would make whatever is checked out here live for the hourly
# timer, the merge tick and every PR event. Running this against
# ~/.claude/skills therefore requires --force over the deployed copies, and
# ./install.sh will in turn refuse to replace the symlinks without --force.
#
# Usage:
#   install_skills_and_actions.sh [--target DIR]... [--force] [--list]
#
#   --target DIR   Skills directory to install into. Repeatable.
#                  Default: ~/.claude/skills (production; see above).
#   --force        Replace whatever already exists at the destination, even a
#                  plain directory. Without it, an existing entry that is not
#                  already the correct symlink is left untouched and reported.
#   --list         Print what would happen; install nothing.
#
# Why Codex is not a default target
#
# ~/.codex/skills/pr-review-resolver is NOT an earlier copy of this one. It is
# a separately maintained variant adapted for AMPB's slice-pipeline --
# scripts/gitea_night, night:* labels, worker-held worktree locks -- sharing
# only the name. Linking this repo's pr-review-resolver over it would silently
# change what AMPB's pipeline runs. Pass --target ~/.codex/skills yourself if
# you specifically mean to replace it, and expect --force to be required.
# The same caution applies to any other skills directory already carrying a
# same-named skill: this script will tell you, not overwrite you.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_SRC="$REPO_ROOT/skills"

targets=()
force=0
list_only=0
while (($#)); do
  case "$1" in
    --target)
      [ $# -ge 2 ] || { echo "--target needs a directory" >&2; exit 2; }
      targets+=("$2"); shift 2 ;;
    --force) force=1; shift ;;
    --list) list_only=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^#!\?//' | sed 's/^ //'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ ${#targets[@]} -eq 0 ] && targets=("$HOME/.claude/skills")

[ -d "$SKILLS_SRC" ] || { echo "no skills/ directory found beside this script ($SKILLS_SRC)" >&2; exit 2; }

status=0
for target in "${targets[@]}"; do
  echo "== $target =="
  [ "$list_only" = 1 ] || mkdir -p "$target"
  for skill_dir in "$SKILLS_SRC"/*/; do
    name="$(basename "$skill_dir")"
    dest="$target/$name"
    link_target="$SKILLS_SRC/$name"

    if [ -L "$dest" ]; then
      current="$(readlink -f "$dest" 2>/dev/null || true)"
      wanted="$(readlink -f "$link_target")"
      if [ "$current" = "$wanted" ]; then
        echo "  $name: already linked, skipping"
        continue
      fi
      if [ "$list_only" = 1 ]; then
        echo "  $name: would replace existing symlink -> $current"
        continue
      fi
      if [ "$force" = 1 ]; then
        rm "$dest"
      else
        echo "  $name: SKIPPED -- a different symlink already exists here ($current). Pass --force to replace it."
        status=1
        continue
      fi
    elif [ -e "$dest" ]; then
      if [ "$list_only" = 1 ]; then
        echo "  $name: would replace existing plain directory (not a symlink)"
        continue
      fi
      if [ "$force" = 1 ]; then
        echo "  $name: replacing existing plain directory (was not a symlink)"
        rm -rf "$dest"
      else
        echo "  $name: SKIPPED -- a plain directory already exists here, not a symlink. Pass --force to replace it, or move it aside yourself first."
        status=1
        continue
      fi
    else
      [ "$list_only" = 1 ] && { echo "  $name: would link"; continue; }
    fi

    ln -s "$link_target" "$dest"
    echo "  $name: linked"
  done
done

exit $status
