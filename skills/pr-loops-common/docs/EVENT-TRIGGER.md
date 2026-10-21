# Event trigger: start the PR loop when a PR is opened or updated

The hourly `pr-pipeline.timer` still runs every stage for every repo. The event trigger adds a
fast path: when Gitea reports a PR event, that one PR goes through label, review and resolve
within minutes. Both paths share the same locks, head markers and label claims, so a PR that
gets an event and a timer tick, or a burst of events, is reviewed once.

```
Gitea pull_request_target
  -> Actions job on the factory-host runner (template owned by TheGiteaCodeFactory)
  -> ~/.local/bin/pr-trigger --repo O/R --pr N --sha HEAD --event E --label L
  -> ~/.local/state/gitea-pr-loops/queue/<owner>__<name>__<pr>.json
  -> pr-trigger-drain.path (DirectoryNotEmpty) -> pr-trigger-drain.service -> ~/.local/bin/pr-drain
  -> [label-prs] -> pr-loop.sh review -> pr-loop.sh resolve   (PR_LOOP_PR=N, PR_LOOP_LOCK_WAIT)
```

The Actions job finishes in well under a second. It writes one file and returns, so it never
holds a runner slot for a 45-minute review, and cancelling it cannot strand a
`review:in-progress` claim.

## The cross-repo contract

These points are shared word for word by TheNightCrew, TheGiteaCodeFactory and this repo.

| | |
|---|---|
| Entry point | `~/.local/bin/pr-trigger --repo OWNER/NAME --pr N --sha HEAD [--event E] [--label L]`, owned and installed by this repo (`install.sh`) |
| Exit codes | `0` accepted or ignored (one-line reason on stdout), `2` bad arguments, `3` misconfiguration or write failure |
| Runner | `factory-host`: a new instance-wide host-mode runner on Craig's PC, provisioned by the Factory's `scripts/setup-host-runner.sh`. `nightcrew-host` is untouched |
| Event | `pull_request_target`, types `opened`, `synchronize`, `reopened`, `labeled`; branches `[develop]`; drafts and forks skipped by the template's `if:` |
| Gitea spellings | Gitea may send `synchronized` for `synchronize` and `label_updated` for `labeled`, and may leave `label.name` empty. `pr-trigger` accepts all of these |
| Labels that fire | `review:requested` and `review:findings`. Any other label is ignored (exit 0) |
| Vocabulary | `review:clean` is canonical. Nothing in this repo reads `review:clear`; it is transitional only in the Factory docs that are being migrated |
| Execution | the queue + systemd path-unit drain described here, owned by this repo |

The template should pass the payload through untouched, for example:

```yaml
env:
  REPO: ${{ github.repository }}
  PR: ${{ github.event.pull_request.number }}
  SHA: ${{ github.event.pull_request.head.sha }}
  EVENT: ${{ github.event.action }}
  LABEL: ${{ github.event.label.name }}
run: ~/.local/bin/pr-trigger --repo "$REPO" --pr "$PR" --sha "$SHA" --event "$EVENT" --label "$LABEL"
```

`pr-trigger` normalises the spellings itself, so contract tests in the other repos should not
assume GitHub's.

## pr-trigger

- **Validation.** repo `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$`; PR a positive integer; SHA 40 or 64
  hex digits (upper case is folded). Anything else exits 2.
- **Events.** `opened`, `reopened`, `synchronize`/`synchronized` queue with a label stage.
  `labeled`/`label_updated` queue only for `review:requested`, `review:findings`, or an empty
  `--label`, which is logged as `label=unknown` and settled by the drainer's live check.
  `manual` or no `--event` queues. Anything else (`closed`, `edited`, ...) exits 0 as ignored.
- **Queue write.** A temp file in `queue.tmp/`, fsynced, then renamed into `queue/`, so the path
  unit never sees a partial file. Same filesystem, so the rename is atomic.
- **Coalescing.** One file per PR. A newer event overwrites one that has not been picked up yet
  and its SHA wins, but a pending label stage survives: `opened` followed by `labeled` still
  runs the label stage. An event that arrives while its PR is being processed gets a fresh queue
  file and runs again afterwards.
- **Logging.** Every call, including rejected and ignored ones, appends one line to
  `~/.local/state/gitea-pr-loops/trigger.log` with the raw event and label. That line answers
  the Gitea behaviour questions below.

Manual use (`--sha` is required by the contract):

```sh
pr-trigger --repo ElasticGun/TheNightCrew --pr 42 --event manual \
  --sha "$(python3 ~/.claude/skills/pr-loops-common/gitea-pr.py head --repo ElasticGun/TheNightCrew --pr 42)"
```

## pr-drain

Run only by `pr-trigger-drain.service`. It holds `drain.lock`, moves leftovers from a killed run
in `processing/` back to `queue/` (unless a newer event already replaced them), then takes the
oldest queued file until the queue is empty. For each PR:

1. **Allowlist.** `PR_PIPELINE_REPOS`, else `php artisan nightcrew:list-pr-repos`, as in
   `pr-pipeline.sh`.
2. **Checkout.** `~/.config/pulse/night_crew_repositories.json`, else `~/Code/<name>`.
3. **Pre-check.** One adapter `list` call. Closed and draft PRs are dropped. A label event with
   no label stage pending is dropped when the PR carries neither `review:requested` nor
   `review:findings`, which turns the loop's own relabel events into one API call.
4. **Label stage**, only for `opened`, `reopened` and `synchronize`:
   `nightcrew:label-prs --repo R --pr N` when `php artisan help nightcrew:label-prs` lists those
   options, otherwise the full sweep.
5. **Review, then resolve.** `pr-loop.sh review` and `pr-loop.sh resolve` with `PR_LOOP_PR=N` and
   `PR_LOOP_LOCK_WAIT=${PR_TRIGGER_LOCK_WAIT:-3600}`. Merge never runs here; it stays the merge
   tick's job.

Every item is consumed, whatever happens, so the path unit cannot spin. There is no retry: if
`pr-loop.sh` skips (box busy, low memory, lock wait exhausted) or Gitea cannot be read, the
hourly timer is the backstop. `PR_LOOP_ENGINE` accepts only `pr-loop` until the agent pool (PR
#2) lands; a follow-up then adds the `pool` engine.

## pr-loop.sh knobs (default off)

- `PR_LOOP_PR=N` restricts the candidate list to PR #N.
- `PR_LOOP_LOCK_WAIT=S` waits up to S seconds for `review.lock`/`resolve.lock` instead of exiting
  at once. The review lock is global across repos, so an event can wait behind a whole hourly
  review stage; hence the 3600 s default in `pr-drain`.
- The log prefix now names the repo: `2026-10-17T12:00:00-04:00 [review] [owner/name] ...`.

With neither variable set, the hourly timer behaves exactly as before.

## systemd units

`systemd/pr-trigger-drain.path` watches `%h/.local/state/gitea-pr-loops/queue` with
`DirectoryNotEmpty=` (and creates it), with `TriggerLimitIntervalSec`/`TriggerLimitBurst` as a
spin guard. `systemd/pr-trigger-drain.service` is `Type=oneshot`, runs `%h/.local/bin/pr-drain`
with the same explicit `PATH` as `pr-pipeline.service`, appends output to `trigger.log`, and has:

- `TimeoutStartSec=infinity`: killing a drain mid-review strands `review:in-progress`, and every
  inner step is already bounded by `WORKER_TIMEOUT` and the lock wait.
- `KillMode=process`: if `pr-loop.sh` happens to start the tmux server, the default kill mode
  would take that server, and every worker on it, down when the drain finishes.

The service starts from the systemd user manager, not from the Actions job, so no job
environment leaks in and `gitea-pr.py` uses `~/.config/pulse/gitea_token`.

## Installing

Production is a copy, deployed by the top-level `install.sh` from a committed revision (see its
header). From a clean `master` checkout:

```sh
./install.sh --list      # what would change, including drift
./install.sh             # deploy skills, ~/.local/bin/pr-trigger and pr-drain, units; enable the path unit
./install.sh --rollback  # swap the previous copy back (again to roll forward)
```

The first deploy finds a live `~/.claude/skills/pr-loops-common` without `.deployed-from`, so it
is compared with the revision being deployed, and the files this change edits (`pr-loop.sh`,
the README) show up as drift. Check that the list is exactly those files, then rerun with
`--force`. Later deploys compare against the recorded revision and need no `--force` unless
someone edited the live copy by hand.

TheGiteaCodeFactory's setup should call `install.sh`, not carry its own copies of the unit files.

## Gitea 1.26.2 behaviour checks

Run on a sandbox repo with the Factory template, reading `trigger.log`.

1. **`pull_request_target` fires on opened, synchronize and reopened.** Record the exact action
   strings (expect `synchronized`). No fallback needed here: both spellings are accepted.
2. **It fires on label add.** Record `labeled` vs `label_updated`, whether
   `github.event.label.name` is populated, and whether it also fires on label removal.
   - Not at all: drop `labeled` from the template. `pr-drain` already chains review into resolve,
     pushes go through the label stage, and a hand-applied `review:requested` is picked up by
     the hourly tick or `pr-trigger --event manual`. Never fall back to `pull_request` on a host
     runner: it runs workflow code from the PR head.
   - Fires with an empty label name: nothing to change; the drainer's live-label check covers it.
3. **`concurrency:` is honoured** (two quick pushes, one group per repo and PR). If not, nothing
   to change: the job is sub-second and the queue file coalesces.
4. **Drafts and forks are skipped** by the template's `if:`. Defence in depth: `pr-drain` drops
   drafts and `pr-loop.sh` skips them anyway.
5. **The path unit re-triggers** when the drain service exits with `queue/` non-empty (queue
   something during a run). `pr-drain` also rescans after releasing its lock, so a trigger that
   lands at the very end is not left waiting.

## Troubleshooting

- `systemctl --user status pr-trigger-drain.path pr-trigger-drain.service`
- `tail -f ~/.local/state/gitea-pr-loops/trigger.log` for triggers and drains;
  `~/.local/state/gitea-pr-loops/pr-loop.log` for the review and resolve ticks.
- `ls ~/.local/state/gitea-pr-loops/{queue,processing}`: a file stuck in `queue/` means the path
  unit is not running (or hit its trigger limit: `systemctl --user reset-failed
  pr-trigger-drain.path` and start it again).
- `pr-trigger` exit 3: the state directory is missing or not writable for the runner's user.
- "gave up waiting 3600s for the review lock": a long hourly review held the lock. The PR keeps
  its label, so the next tick picks it up.
- `cat ~/.claude/skills/pr-loops-common/.deployed-from` shows which commit is live.

## Security note

`factory-host` is instance-wide: any repo on the Gitea instance whose workflow says
`runs-on: factory-host` runs as `craigpar` on the PC, not only repos registered through
TheNightCrew. `pull_request_target` protects against PR authors, not repo owners. That is
acceptable only while every Gitea account belongs to Craig or his agents.
