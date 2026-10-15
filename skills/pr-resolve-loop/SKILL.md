---
name: pr-resolve-loop
description: Run one tick of the label-driven PR resolve loop for any Gitea repo (default craigpars/AgileMedievalPeasantBoard, override PR_LOOP_REPO). Every open PR labelled review:findings gets its own tmux Claude worker that runs the pr-review-resolver skill against the posted review, commits fixes, runs the gate, and pushes fast-forward to the PR branch; the label moves to review:resolved. Never merges. Use when asked to "resolve the reviewed PRs", "run the resolve loop", or to check why a resolve did not land.
---

# pr-resolve-loop

The fix half of the PR loop. Same script as the review loop, in `resolve` mode.

Operator setup, prerequisites, and cron are in
[`docs/agents/pr-loops-setup.md`](../../../docs/agents/pr-loops-setup.md).

## What a tick does

1. Same guards as the review loop: `flock`, busy-box check, memory check.
2. Lists open PRs carrying **`review:findings`**, drops drafts and bot authors, and checks that
   the review marker names the CURRENT head. If the PR gained a commit since the review, the
   findings are stale: the PR goes back to `review:requested` and is not touched.
3. For up to `MAX_PARALLEL` of them: relabels to `review:resolving`, makes a detached worktree at
   the head, starts `prloop-resolve-<n>` running `claude --permission-mode auto` with the review
   allow list plus Edit/Write, `git add/commit`, `git push origin HEAD:*`, and the gate commands;
   the deny list still refuses merge, auto-merge, force-push, reset, branch deletion, and any
   `gh pr edit`. Pastes the worker prompt and waits for `PR_RESOLVE_DONE`.
4. Verifies with `tea` + the Gitea adapter: the worker's `pulse-resolve:v1` marker must answer the review that
   triggered the run and account for every finding; a claimed fix must have moved the PR head as
   a fast-forward. Then relabels `review:resolved`, or `review:needs-human` with a comment
   (findings deferred to a person, nothing pushed, non-fast-forward, timeout, stall, parked pane).
5. Kills the session. Removes the worktree only if it is clean; a worktree with uncommitted work
   is left in place and named in the log so nothing is lost.

The worker is told to post one "## Automated resolve" comment listing each finding as fixed, noted or
blocking with a drafted reply, so a human can post the replies and merge. It never replies to
or resolves threads itself.

Each finding ends up **fixed**, **noted** or **deferred** (marker
`fixed= noted= deferred=`). Noted findings are suggestions and preferences that would be fine to
merge as they are: they are listed for the author in the comment and do not block, so a PR with
only fixed and noted findings reaches `review:resolved`. `review:needs-human` means at least one
finding is **blocking** (a defect or contradiction the resolver could not fix safely, or a parity
observation), and the comment's Blocking section says which.

## Run it

From the repository root:

```bash
~/.claude/skills/pr-loops-common/pr-loop.sh resolve
DRY_RUN=1 ~/.claude/skills/pr-loops-common/pr-loop.sh resolve
tail -50 ~/.local/state/pulse-pr-loops/pr-loop.log
```

Run it in the background; a tick waits for its workers. When invoked, run the tick, then report
the log lines, the new head of each PR it pushed to, and any worktree it left behind.

## Known adaptation

`/pr-review-resolver` is written for a single interactive run. The worker prompt
(`prompts/resolve.txt`) tells it to work in the loop's worktree instead of making its own, to
treat the "## Automated review" comment's numbered findings as threads, and to finish with the
disposition marker the loop verifies.

## Safety

Three layers refuse the irreversible actions: the resolver skill's own rules, the launch deny
list (including the merge adapter), and the repo hook `.claude/hooks/pipeline-guardrails.mjs` once
it lands on `develop` (it is on `feature/pipeline-guardrails-hook` today). This worker never
merges; any later merge is a separate, human-opted-in `/pr-merge-loop` tick.
