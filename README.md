# pr-loop-skills

A label-driven review, resolve, and merge loop for Gitea pull requests, plus
the Claude Code skills that drive it. GitHub support is not implemented —
the adapter is Gitea-only. Originally deployed loose under `~/.claude/skills/`,
never version controlled; this is that same content, given a real home.

## Plans
I want to set something up that automatically loops between reviewing and review resolving.

Once a person or bot is satisfied it gets labeled Auto-merge and if the person deems this to be worthy merges it. If there are merge issues, then deal with them and then merge unless the CI quality gates don't let it pass.

This is recommended for develop only and should never be hooked up to production.

An alternate form of this I would like to enable are long living feature branches. This goes against my ideals, no branch except main or develop should be long lived. However for A.I. long lived isn't very long. This is also for the purposes of Auto merging.

## What's here

- `skills/pr-loops-common/` — the engine. `pr-loop.sh` (list, filter, spawn one
  tmux worker per PR, wait, verify, relabel) for review and resolve,
  `pr-merge.sh` for the separate merge tick, `gitea-pr.py` (the Gitea
  adapter), `marker.py` (hidden-marker parsing), worker prompts.
- `skills/pr-review-loop/`, `skills/pr-resolve-loop/`,
  `skills/pr-review-resolve-loop/` — thin wrappers that each run `pr-loop.sh`
  in a specific mode.
- `skills/pr-review-resolver/` — the skill a resolve worker actually runs:
  address review comments or conflicts, land the fix on the PR's branch, never
  merge.
- `skills/pr-merge-loop/` — a **third, deliberately separate, mechanical**
  tick. No model worker at all: it merges only PRs an operator has explicitly
  labelled `review:automerge`, that also carry `review:clean` or
  `review:resolved`, after re-verifying the marker, head, mergeability, and
  base branch immediately before calling `tea pr merge`. Review and resolve
  workers are denied `tea pr merge` and every merge-adjacent command outright
  — merging only ever happens through this one path. Allowlisted per-repo
  (`PR_MERGE_ALLOW_REPOS`, currently only `ElasticGun/TheNightCrew`) and
  requires explicit per-session authorization before a real (non-dry) run;
  see `skills/pr-loops-common/docs/HANDOFF-pr-automerge.md` for why it's
  structured this way.

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
