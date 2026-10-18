---
name: pr-merge-loop
description: Run the separate mechanical Gitea PR merge tick for allowlisted repositories. It merges only open, non-draft, non-bot PRs explicitly labelled review:automerge plus review:clean, review:resolved or agent:done after marker/head, mergeability, and base-branch gates pass. Use when asked to run or inspect the PR auto-merge tick. Never invoke it from the review or resolve workers.
---

# PR merge loop

Run one deterministic merge tick. This skill starts no model worker and is separate from the
review and resolve loops.

```bash
~/.claude/skills/pr-loops-common/pr-merge.sh
```

The phase-one default and allowlist contain only `ElasticGun/TheNightCrew`, target `develop`, use
merge style `merge`, keep the source branch, and require `review:automerge`. To inspect candidates
without claiming, relabelling, commenting, or merging:

```bash
DRY_RUN=1 ~/.claude/skills/pr-loops-common/pr-merge.sh
```

Run the real tick only when the user has explicitly authorized merges in the current session.
Otherwise run the dry form and report its `[merge]` log lines. Never call this skill or its script
from a review/resolve worker.

The tick claims eligible PRs as `review:merging`. It verifies the path-specific marker against the
current head, requires the configured base, and calls the adapter's explicit merge subcommand,
which rechecks the live head, base, draft/open state, and `mergeable == true` immediately before
wrapping `tea pr merge`. Success becomes `review:merged`; any gate or merge failure becomes
`review:needs-human` with a reason comment.

Configuration: `PR_LOOP_REPO`, `PR_MERGE_ALLOW_REPOS` (comma-separated), `PR_MERGE_BASE`,
`PR_MERGE_STYLE`, and `PR_LOOP_STATE`. Required-status-context enforcement is deferred until the
repositories have CI and branch protection.
