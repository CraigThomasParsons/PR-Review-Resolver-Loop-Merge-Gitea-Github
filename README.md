# pr-loop-skills

A label-driven review-and-resolve loop for Gitea pull requests, plus the Claude
Code skills that drive it. Originally deployed loose under
`~/.claude/skills/`, never version controlled; this is that same content,
given a real home.

## What's here

- `skills/pr-loops-common/` — the engine. `pr-loop.sh` (list, filter, spawn one
  tmux worker per PR, wait, verify, relabel), `gitea-pr.py` (the Gitea
  adapter), `marker.py` (hidden-marker parsing), worker prompts.
- `skills/pr-review-loop/`, `skills/pr-resolve-loop/`,
  `skills/pr-review-resolve-loop/` — thin wrappers that each run `pr-loop.sh`
  in a specific mode.
- `skills/pr-review-resolver/` — the skill a resolve worker actually runs:
  address review comments or conflicts, land the fix on the PR's branch, never
  merge.

See `skills/pr-loops-common/docs/pr-loops-setup.md` for the full operator
setup and `skills/pr-review-resolver/SKILL.md` for the resolver's own rules.

## Installing

```sh
./install_skills_and_actions.sh              # symlinks into ~/.claude/skills
./install_skills_and_actions.sh --list        # dry run
./install_skills_and_actions.sh --target DIR  # install somewhere else too
```

Symlinked, not copied: editing a skill here takes effect immediately wherever
it's installed. The script never overwrites an existing plain directory or a
differently-targeted symlink without `--force` — see the script's own header
comment for why `~/.codex/skills/pr-review-resolver` specifically should not
be a default target. It is a separately maintained variant adapted for AMPB's
slice-pipeline, not an older copy of this one.

## Not version controlled before this

The content here is the real, currently-running engine — not the older
GitHub/`gh`-oriented ancestor documented in scattered, untracked copies
elsewhere on this machine (different tracker, different paths, same original
idea). This repo starts from the version that is actually deployed and
observed working.
