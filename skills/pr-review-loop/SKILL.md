---
name: pr-review-loop
description: Run one tick of the label-driven PR review loop for any Gitea repo (default craigpars/AgileMedievalPeasantBoard, override PR_LOOP_REPO). Every open PR labelled review:requested gets its own tmux Claude worker that runs the mattpocock-skills:code-review skill and posts the report as a PR comment; the label moves to review:findings (or review:clean). Skips bots, nightly chore PRs, drafts, and already-reviewed heads. Use when asked to "review the labelled PRs", "run the review loop", or to check why a review did not happen.
---

# pr-review-loop

One tick of the review half of the PR loop. The loop body is a script; this skill runs it and
reads back what it did. Tokens are spent only inside the per-PR workers.

Operator setup, prerequisites, and cron are in
[`docs/agents/pr-loops-setup.md`](../../../docs/agents/pr-loops-setup.md).

## What a tick does

1. Refuses to overlap itself (`flock`), and skips the tick when another `pulse-*` tmux worker is
   mid-task or the box has under 6 GB available. Memory is the real limit on a workstation.
2. Lists open PRs carrying **`review:requested`**, and drops drafts, bot authors (Dependabot
   included), and any PR whose head already carries a review marker.
3. For up to `MAX_PARALLEL` (default 2) of them: flips the label to `review:in-progress`, makes a
   detached worktree at the PR head under `<parent of the clone>/.prloop-worktrees/prloop-review-<n>`,
   starts a tmux session `prloop-review-<n>` running `claude --permission-mode auto` with a
   read-only allow list and a deny list (no merge, no force-push, no reset, no label edits),
   pastes the worker prompt, and waits for the sentinel `PR_REVIEW_DONE`.
4. Verifies with `tea` + the Gitea adapter, not with the worker's word: the newest PR comment must end with
   `<!-- pulse-review:v1 head=<sha> findings=<n> -->` for the head it reviewed. Then relabels:
   `review:findings` (n > 0), `review:clean` (n = 0), or `review:needs-human` with a comment
   saying why (no marker, timeout, stall, parked pane).
5. Kills the session and removes the worktree.

## Run it

From the repository root:

```bash
~/.claude/skills/pr-loops-common/pr-loop.sh review            # one real tick
DRY_RUN=1 ~/.claude/skills/pr-loops-common/pr-loop.sh review  # list and explain, touch nothing
tail -50 ~/.local/state/pulse-pr-loops/pr-loop.log          # what the last ticks decided
```

A tick waits for its workers, so it can outlast a 10 minute foreground command. Run it in the
background and wait for it to exit.

When this skill is invoked, run the real tick (or the dry run if the user asked to check first),
then report the log lines it produced and the resulting labels on the PRs it touched. If a worker
was marked `review:needs-human`, the script has already killed its session, so read the loop log
and the PR comment for the reason.

Knobs: `MAX_PARALLEL`, `WORKER_TIMEOUT` (default 2700 s), `POLL` (30 s), `MIN_FREE_GB` (6),
`SKIP_BUSY_GUARD=1`.

## To queue a PR

`gh pr edit <n> --add-label review:requested`. Re-labelling a PR whose head was already reviewed
does nothing until it gains a new commit; that is the marker doing its job.

## Files

- `~/.claude/skills/pr-loops-common/pr-loop.sh` the loop (both modes)
- `.agents/skills/pr-loops-common/prompts/review.txt` the worker prompt
- `.agents/skills/pr-loops-common/marker.py` reads the hidden marker
- `.agents/skills/pr-loops-common/classify-pane.sh` classifies a worker pane each poll
- `~/.local/state/pulse-pr-loops/` lock, log, per-run prompt and launch files

## Safety

Never merges, never enables auto-merge, never force-pushes, never edits labels from inside a
worker. The review worker is read-only by allow list and explicitly denied the merge adapter.
Any later merge is a separate, human-opted-in `/pr-merge-loop` tick. A parked pane (usage limit,
login prompt) fails the PR to `review:needs-human` rather than being nudged forever.
