---
name: pr-review-resolver
description: Address code-review comments on a Gitea PR. Read the unresolved threads, fix them in code on the PR's own branch, run the gate, and push. Use when asked to resolve or address PR review feedback, or to resolve merge conflicts on a PR. NEVER merges, NEVER enables auto-merge, NEVER force-pushes, and NEVER resolves or replies to threads on Gitea; the independent merge gate owns merging.
---

# PR Review Resolver

Address a reviewer's comments on a pull request, or resolve its merge conflicts, and **land the
fix on the PR's branch**. You do the work and push it; the independent merge gate owns merging.

The line is drawn at **merging**, not at pushing. A fix that never reaches the branch resolves
nothing: the PR stays conflicted, stays in draft, and the person who asked is still blocked.

The resolve loop (`/pr-resolve-loop`) runs this skill unattended, one worker per PR. Its prompt
adapts some of the steps below; see `.agents/skills/pr-loops-common/prompts/resolve.txt`.

## Hard rules, do not break

- **Never merge the PR and never enable auto-merge.** Not because merging needs a human — the
  label-driven merge gate (`/pr-merge-loop`) automates it behind `review:automerge` plus
  `review:clean`/`review:resolved` and its marker, head, mergeability and base-branch checks.
  Merging is simply not this worker's job; keep the roles separate. This is the rule that
  matters; everything else is mechanics.
- **Never force-push, never `git reset --hard`, never delete a branch.** Push plainly, and only
  ever as a fast-forward. If a push would need a force flag, stop and report instead.
- **Never reply to or resolve review threads on Gitea.** You only *draft* replies into the
  summary file, so the human decides what gets said.
- Touch only the files a comment is about. Keep each change the smallest correct fix.
- Give every comment one disposition. Ask: would the PR be fine to merge with this comment
  left exactly as it is?
  - **fixed**: you made the smallest correct change.
  - **noted** (yes, fine to merge): suggestions, conventions, style or process preferences,
    optional follow-ups. Change nothing; draft a reply or question for the author. Does not
    block the PR.
  - **needs-human** (no, and you can't fix it confidently): a real defect, a contradiction with
    the issue, an ADR or a documented standard, or a fix that needs a decision first. **Do not
    guess.** This is the only disposition that stops the PR.
  Never downgrade a real defect to noted, and never invent a fix for a design question.
- Never modify the behavioral oracle if one is referenced (e.g. another repo's `server/`).

## Inputs (from the prompt)

- The **PR number** and that the repo is the current working directory.
- A **timestamp/suffix** to use for the branch (do not invent one; the runtime forbids it).
- The **summary file** path to write.

## Steps

1. `cd` is already the target repo. Read its AGENTS.md (or CLAUDE.md) for the gate and frozen
   paths, then the review state through the loops' Gitea adapter
   (`~/.claude/skills/pr-loops-common/gitea-pr.py`):
   `python3 <adapter> threads --repo <O/R> --pr <N>` for unresolved inline comments, and
   `python3 <adapter> comments --repo <O/R> --pr <N>` for review comments on the PR.
2. Work in a fresh worktree off the PR's head branch so you never disturb the user's checkout:
   `git worktree add <path> -b review/<pr>-<suffix> origin/<head-branch>`.
3. For each unresolved thread, make the smallest correct change. If the PR is conflicted, resolve
   the conflicts here too. Run the repo's build/tests and get them green.
4. Draft a reply per thread (what changed + why). **Do not post it.**
5. Commit with a clear message, then **push to the PR's own branch**:
   `git push origin HEAD:<head-branch>`. Confirm first that it is a fast-forward
   (`git merge-base --is-ancestor origin/<head-branch> HEAD`); if it is not, stop and report
   rather than reaching for a force flag.
6. If the PR is a draft and the work is now complete, say so in the summary so a person can
   take it out of draft. Never merge it.
7. Write the summary file (below), and report anything you judged but did not change.

**A conflict resolution is a judgement call, not a mechanical merge.** Before resolving, check
what actually changed on the base since the branch was cut. A file the branch deletes may have
been rewritten by someone else in the meantime, so taking either side blindly can destroy work
that has nothing to do with this PR. Say what you chose and why, in the commit message.

## Summary file format

```
# PR #<N> review, <suffix>
branch: review/<pr>-<suffix>
tests: <pass|fail + one line>

## thread <id>  (<file>:<line>)  [fixed|noted|needs-human]
ask: <the reviewer's comment, condensed>
change: <what you did, or why you didn't>
draft-reply: <the reply to post after the human approves>
```

End your run with one status line: branch name, threads fixed, noted count, needs-human count, test result,
whether the push landed, and the summary path, so the watcher can mark the run ready for review.
