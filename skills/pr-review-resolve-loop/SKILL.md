---
name: pr-review-resolve-loop
description: Run the review tick and then the resolve tick of the label-driven PR loop for any Gitea repo (default craigpars/AgileMedievalPeasantBoard, override PR_LOOP_REPO), back to back, so a PR labelled review:requested can go all the way to review:resolved in one invocation instead of waiting for the two crons. Runs /pr-review-loop's script, waits for every review worker to finish, then runs /pr-resolve-loop's script. Never merges. Use when asked to "review and resolve the labelled PRs", "run both PR loops", "run the full PR loop", or "take this PR from requested to resolved now".
---

# pr-review-resolve-loop

A review tick followed by a resolve tick. It adds no logic of its own: both halves are the same
`pr-loop.sh` the crons run, and each half keeps its own guards, verification, and relabelling.
See `/pr-review-loop` and `/pr-resolve-loop` for what each tick does, and
[`docs/agents/pr-loops-setup.md`](../../../docs/agents/pr-loops-setup.md) for setup.

## Why it chains cleanly

`pr-loop.sh` waits for every worker it spawned before it exits, and relabels only after `tea` + the Gitea adapter has
verified the result. When the review tick returns, every PR it reviewed already carries
`review:findings`, `review:clean`, or `review:needs-human`. The resolve tick that follows sees
those labels. Running the two ticks one after the other also keeps a workstation to one heavy job
at a time.

## Run it

The whole run can take well over the 10 minute foreground limit (each worker may run for up to
`WORKER_TIMEOUT`, 2700 s by default), so run it in the background and wait for the completion
notification. Don't poll it. From the repository root:

```bash
~/.claude/skills/pr-loops-common/pr-loop.sh review && ~/.claude/skills/pr-loops-common/pr-loop.sh resolve
```

It uses `&&` because the script exits 2 only on a setup fault (missing tool, `tea` + the Gitea adapter failure). A
fault like that would break the resolve tick too. A normal tick exits 0 even when it had nothing
to do or skipped itself.

To check first without touching anything:

```bash
DRY_RUN=1 ~/.claude/skills/pr-loops-common/pr-loop.sh review; DRY_RUN=1 ~/.claude/skills/pr-loops-common/pr-loop.sh resolve
```

A dry run of resolve can't see what the review tick is about to produce. It only lists PRs
that already carry `review:findings`.

## Report

After both ticks, read `~/.local/state/pulse-pr-loops/pr-loop.log`. The `[review]` and
`[resolve]` tags tell the two halves apart. Report:

- each PR the review tick touched, and its label afterwards
- each PR the resolve tick touched: the new head it pushed, its label afterwards, and any
  worktree it left behind
- any `review:needs-human` result with the reason from the log line and the PR comment
- a tick that skipped itself (lock held, `pulse-*` session busy, under `MIN_FREE_GB`), so a quiet
  run isn't mistaken for "nothing queued"

## Things to expect

- The resolve tick works through every PR carrying `review:findings`, including ones reviewed by an
  earlier cron run, not only the ones reviewed seconds ago.
- The review tick handles at most `MAX_PARALLEL` (default 2) PRs. Anything past that stays at
  `review:requested` for the next run.
- If the review tick skipped for memory or a busy box, the resolve tick will usually skip for the
  same reason.
- The knobs (`MAX_PARALLEL`, `WORKER_TIMEOUT`, `POLL`, `MIN_FREE_GB`, `SKIP_BUSY_GUARD`) are
  environment variables. Put them in front of both commands if they should apply to both ticks.

## Safety

Same as the two halves: never merges, never enables auto-merge, never force-pushes. Any later merge
is a separate, human-opted-in `/pr-merge-loop` tick.
