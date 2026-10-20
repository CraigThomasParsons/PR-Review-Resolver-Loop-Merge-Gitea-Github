# Controller-commits-everything

Status: design plan, split out of `docs/plans/provider-capabilities.md` on 2026-10-20 (decision:
the two are orthogonal — this is a worker-permission/security-architecture change, the capability
model is a claim-routing change — and bundling them made the review surface and rollback blast
radius bigger than either needed). Treat this as a prerequisite plan for
`docs/plans/provider-capabilities.md`'s `prototype` and `test-author` abilities specifically
(neither has an existing fallback mechanism); `resolve` keeps today's existing worker-commits-
locally-controller-pushes-only mechanism until this plan lands, then migrates onto it too.

## Context

Today, during `resolve`, workers still run `git add <named paths>` and `git commit -m <msg>`
themselves so the worker knows the commit SHA for its marker; the controller only pushes. This
plan moves **all** commits to the controller, so no worker ever runs `git add`, `git commit`, or
`git push`, or any gate command, regardless of ability or provider.

## 1. Worker permissions (`agent-pool/scripts/policy.py`)

- `COMMIT_SHELL` (`git add *`, `git commit -m *`) and the `sub in ("add", "commit")` branches in
  `segment_ok()` (`agent-pool/scripts/policy.py`, lines 293-300, 337) are deleted.
- Every provider worker has the exact same read-only git command set (`git status`, `git diff`,
  `git log`, `git show`), enforced by CLI rules, hooks, and the `workerbin/git` PATH shim.
- Workers never write to `.git` or the git index.

## 2. Creating signed commits with trailers in `agent-pool/bin/prod-common.sh`

New controller function `controller_commit()` runs after the worker process group is killed
(`kill_worker_group`) and `still_held` is verified. Using `gate_git` (the scrubbed git wrapper
from `docs/plans/controller-gates.md` Section 2.2) and a temporary index file
`$RUNS/index-$JOB_PR-${ATTEMPT:0:8}` initialized from `$sha`:

1. The controller inspects modified and untracked files inside `$JOB_WT` via
   `gate_git --work-tree="$JOB_WT" status --porcelain -z`, ignoring excluded tool config paths
   (`.cursor/`, `.grok/`, `.claude/`, `.agent-pool-context.md`, `.agent-pool/`).
2. It verifies no changed path matches the protected set (`gates.py protected`) or credential
   filename patterns (`AGENTS.md`).
3. For `test-author`, it verifies every changed path matches `test_paths` from
   `.agent-pool/gates.toml`.
4. It stages the validated paths into the private index
   (`GIT_INDEX_FILE="$idx" gate_git --work-tree="$JOB_WT" add -- <paths>`), writes a tree object
   (`gate_git write-tree`), and runs `report.py scan` on the unified diff between `$sha` and the
   new tree.
5. For gated abilities (`resolve` and `test-author`), it checks out the candidate tree into
   `$GATE_DIR` and runs `gates.py run` (`docs/plans/controller-gates.md` Section 2). If gates
   fail, no commit ref is updated and nothing is pushed.
6. It builds the commit message from the report's summary line (or
   `chore(<ability>): automated <ability> for #<pr>`) followed by mandatory structured trailers:
   ```text
   <summary line from report>

   Agent-Pool-Provider: <provider>
   Agent-Pool-Ability: <ability>
   Agent-Pool-Worker: <worker_id>
   Agent-Pool-Attempt: <attempt_id>
   Agent-Pool-Model: <model_or_default>
   ```
7. It creates a signed commit in `$MAIN`:
   ```bash
   newhead="$(gate_git_signed commit-tree "$tree_sha" -p "$sha" -S -F "$msg_file")"
   ```
   Because `commit-tree` operates purely on `$MAIN`'s object database and the private index, it
   never executes worktree hooks or reads `.git/config` inside `$JOB_WT`.

## 3. Marker head stamping (`agent-pool/scripts/report.py` and `skills/pr-loops-common/marker.py`)

- Because the worker exits before the controller creates the signed commit, the worker writes
  `head=pending` (or `head=<sha>` when `fixed=0`) in its `pulse-resolve:v1` or
  `pulse-test-author:v1` marker.
- `report.py` validates the marker structure (`reviewed=`, `fixed + noted + deferred == findings`,
  secret scan) with `head=pending` before commit creation, and a new subcommand
  `report.py stamp-head --file "$report" --head "$newhead"` rewrites `head=pending` to
  `head=$newhead` right after `controller_commit()` succeeds and before `comment_file()` posts
  the report.
- `skills/pr-loops-common/marker.py` remains unchanged: the comment posted to Gitea always
  carries the final 40-hex `head=<newhead>` SHA, so `verify()` in `prod-common.sh` and
  `skills/pr-loops-common/pr-merge.sh` work without modification.

## 4. Decisions (settled 2026-10-20)

**Commit signing: SSH signing key, controller-only, required.** `gate_git_signed` uses
`gpg.format=ssh` with a dedicated controller-only key file (never reachable from
`spawn_worker`/`bwrap`, outside `$SSH_AUTH_SOCK`), matching this codebase's existing SSH-based
auth pattern rather than introducing a new GPG keyring. `AGENT_POOL_GIT_SIGN` has no "optional"
mode: a host with no signing key configured is a `SETUP FAULT`, not a silent unsigned commit.
The key needs the same hygiene as every other secret in this system — never committed, never
logged, with a documented rotation path — before this plan ships.

**Commit granularity: one signed commit per ability run.** Workers do not leave a structured
multi-commit manifest. Per-finding disposition still lives in the commit body (via the report
summary) and the PR comment. Revisit a `.agent-pool-commits.json` manifest replay only if a real
need for multiple discrete commits per run shows up in practice.

## 5. Migration (prerequisite to `docs/plans/provider-capabilities.md` Step 2 onward)

- **Files**: `agent-pool/bin/prod-common.sh`, `agent-pool/scripts/policy.py`,
  `agent-pool/scripts/report.py`, `skills/pr-loops-common/prompts/resolve.generic.txt`,
  `scripts/tools/night_shift.sh`.
- Add `controller_commit()` in `agent-pool/bin/prod-common.sh` using a private index,
  `commit-tree -S`, and the `Agent-Pool-Provider`, `Agent-Pool-Ability`, `Agent-Pool-Worker`,
  `Agent-Pool-Attempt`, and `Agent-Pool-Model` trailers.
- Add `report.py stamp-head` and allow `head=pending` in pre-commit worker reports.
- Remove `git add` and `git commit` (`COMMIT_SHELL` and the `add`/`commit` branches of
  `segment_ok`) from `agent-pool/scripts/policy.py`.
- Invert the `git add` and `git commit` allow tests in `agent-pool/tests/verify-lease.sh` and
  `agent-pool/tests/verify-providers.sh` so worker-side `git add` and `git commit` are asserted
  as `deny`, and verify that `prod-common.sh` produces signed commits with trailers on `resolve`.
- Set up the controller-only SSH signing key and its rotation documentation before merging.
