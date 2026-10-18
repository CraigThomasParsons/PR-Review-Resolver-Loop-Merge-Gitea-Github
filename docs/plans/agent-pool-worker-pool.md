# Multi-provider agent worker pool: pull-based prods + a non-LLM doctor

## Context

Today's session diagnosed a stale `ANTHROPIC_API_KEY` (in `.zshrc`, inherited by every
tmux-spawned shell including every `pr-loop.sh` worker) that forced Claude Code onto an
exhausted API-billing account instead of the subscription. Two PRs (#612, #134) were caught
failing silently in ~32 seconds, mislabeled `review:needs-human` with no indication the real
cause was a credit wall, not a genuine defect needing judgment.

The user's diagnosis of the *underlying* problem is broader than one leaked key: the whole
architecture is **push-based** — an orchestrator guesses a provider is available, dispatches to
it, and only discovers unavailability when the dispatched worker goes silent. They want to
invert this to a **pull-based** model, explicitly modeled on real Agile Scrum: five independent
provider workers (Codex, Claude, Agy, Grok, Cursor) each wake hourly via a systemd timer ("a
prod"), pull a job from the existing Gitea label-based queue themselves, and work it. A
separate, deliberately non-LLM "doctor" process detects when a provider has gone silent past
its expected completion time, reassigns the job back to the queue, and arranges for that
provider's *next* prod to say "your task was reassigned, go pick a new one" instead of
"continue" — closing the exact gap today's incident exposed: workers that die with no chance to
self-report.

This plan covers the **prove-it-out phase only**, inside the already-created
`PR-Review-Resolver-Loop-Merge-Gitea-Github` repo (local clone staged at `/tmp/pr-loop-skills`,
real clone should land under `/home/craigpar/Code/`). Porting this into the publicly-shared
`TheGiteaCodeFactory` repo is an explicitly separate, later phase (already agreed with the user)
and is out of scope here.

### Audit finding (confirms the urgency, informs scope)

Grepping `~/.local/state/gitea-pr-loops/pr-loop.log` for the exact fail signature
(`no ... comment carrying the marker`) and computing spawn-to-fail duration per instance found
**12 occurrences clustered tightly at 31-33 seconds** — the credit-wall fingerprint, not a
generic failure — spanning **2026-10-06 through 2026-10-15** across at least 11 distinct PR
numbers (the log doesn't record repo name, so some could be the same PR number in different
repos; that ambiguity is itself worth fixing in the new pool's logging). One outlier (#49,
166s) is likely a different, unrelated failure and should not be lumped in. This confirms two
things: the real blast radius is roughly a dozen silently-mislabeled PRs over nine-plus days,
not two; and `pr-pipeline.timer` (hourly) / `pr-merge-tick.timer` (every 15 min) have been
running this whole time, unattended, across however many repos
`php artisan nightcrew:list-pr-repos` returns.

**Immediate, separate follow-up** (not part of this plan's build, should happen right after
plan approval): relabel the ~12 affected PRs back to `review:requested` so they get a real
review now that the key is fixed, the same way #134 was manually re-verified this session.

### Revision note

A `/codex:adversarial-review` pass against the first draft of this plan returned verdict
`needs-attention` with five `[high]` findings: the staleness comparison double-counted
`claimed_at`; reassignment had no ownership fencing, so a slow or still-exiting worker could
corrupt a replacement's claim; local-file-then-Gitea-label write ordering had no reconciliation
rule for a crash between the two; the terminal-log staleness check wasn't scoped to a specific
attempt, so one attempt's logged failure could mask a later silent one; and the fast EXIT-trap
path released a job without recording a cooldown, so the exact motivating credit-wall failure
would just keep re-claiming and re-failing forever. All five are addressed below — this is not
the original design with footnotes, the claim/staleness/handoff section and verification plan
were both revised to fix them structurally.

### Mailbox revision

Recovery notices now live in a durable, provider-independent worker mailbox owned by
`prod-common.sh`. Agent-talk is optional transport, not a recovery prerequisite. This
supersedes the earlier reset-on-read mutable prompt design.

## Decisions made this session (do not re-litigate)

- **Worker mailbox:** local atomic files for v1, addressed by stable `worker_id`
  (for example `ubuntu-cursor-1`), not provider name. Launchers deliver pending notices
  through each provider's normal prompt input; native live inbox integration is unnecessary.
- **Repo shape:** one shared repo/codebase, deployed as five systemd timer instances — not five
  separate repos.
- **Job queue:** existing per-project Gitea issue/label queues, not a new unified queue.
- **Label namespace:** a **new** `agent:ready` / `agent:claimed` / `agent:done` /
  `agent:needs-human` set, not reused `review:*` labels — three live automations
  (`pr-pipeline.timer`, `pr-merge-tick.timer`, manual ticks) are actively reasoning about
  `review:*` right now; a second queue on the same labels risks a worker claiming something
  `pr-loop.sh`'s own filter is simultaneously evaluating.
- **Reassignment target:** back into the open queue (relabel to unclaimed), not a named
  specific provider. The user's own phrasing — "add a job into the queue for something else
  to... take over their job" — already says this; a doctor that hands work to a *named*
  provider is closer to the manager-prodding anti-pattern this design exists to invert.
- **First-cut scope:** build and test **Claude and Codex only** — the two providers with
  already-confirmed, edit-capable, non-interactive CLI shapes (`claude -p`, `codex exec`).
  `prod-common.sh` is written provider-parameterized from day one so Agy/Grok/Cursor are pure
  additive follow-ups once their individual gaps (listed below) close — not a redesign.
  **Superseded by owner decision (PR #2 review):** the Cursor, Agy and Grok adapters that were
  built alongside Claude and Codex stay in. They are not trimmed back to Claude and Codex.
  `PROVIDER_ORDER` still defaults to Claude alone, and Codex is never in the default order, so
  nothing beyond Claude runs unless an operator lists it.

## Owner decisions from the PR #2 review (binding for the build)

- **Labels and job kind.** The pool uses the `agent:ready` / `agent:claimed` / `agent:done` /
  `agent:needs-human` labels above, never `review:*`. There is no review/resolve mode argument:
  the job kind is derived per PR from its markers. A review marker for the current head with
  findings > 0 means resolve. A clean review marker, or a resolve marker that already answered
  the latest review at the current head, is settled to `agent:done` without running a provider.
  Anything else is a review. A review with findings goes back to `agent:ready`, queued for the
  resolve.
- **Write-once claims.** Heartbeat-renewed leases are gone. `scripts/claim-record.py`
  implements the v2 claim record, attempt fencing and reconciliation table below. A provider
  fallback inside one job is a new attempt (`reattempt`): a fresh `attempt_id` and deadline
  naming the provider actually running, written atomically over the old record. This keeps
  records write-once and fences off the previous provider's stragglers.
- **Workers never publish.** Workers only read, edit, commit locally (resolve) and write a
  report file. If they cannot write files, the report is their final response. The controller,
  `bin/prod-common.sh`, confirms the claim is still held. It then validates the report's marker
  and its finding counts, and checks that the worker's commits fast-forward the reviewed head.
  It also checks that `origin/<headref>` has not moved, then pushes `HEAD:refs/heads/<headref>`
  and posts the report, every write through `claim-record.py guard`. It never pushes a
  protected branch (develop, main, master, release, `release/*`) or a `+` refspec, and never
  force-pushes.
- **Worker containment.** Each worker runs under `setsid` in its own process group, with
  `remote.origin.pushurl` overridden to a dead path in its environment. A read-only watcher
  (not a renewer) re-reads the claim every `AGENT_POOL_WATCH_SECS`. If the attempt is
  superseded, the watcher kills the whole group. Stragglers are killed when the worker exits.
- **Permissions are an allowlist** (`scripts/policy.py`, one policy translated per CLI). It
  allows specific read commands, the adapter's `head|comments|threads` reads by absolute path,
  named-path staging and `git commit -m` (resolve only; `-F` and `--file` are denied), and named
  gate commands. It never allows `python3 *`, `node *`, `npx *`, broad `git`, or any push or
  Gitea write. Explicit denies for `git push --force`, `git reset --hard` and `git merge` stay
  in the policy of every adapter that takes a rule list, and deny rules never depend on an
  absolute path alone. Cursor runs without `--force`, using a per-worktree `.cursor/cli.json`.
  Agy has no rule list. It reviews in `--mode plan`, and the controller posts its `response`. It
  takes resolve jobs only with `AGY_AUTO_APPROVE=1`.
  **Codex is exempt from the rule list too, by owner decision** (PR #2 review, Spec 1): it runs
  with `--sandbox workspace-write`, which has no network and confines filesystem writes to the
  worktree, so it cannot push or write to Gitea regardless of what `policy.py` would allow. The
  sandbox does not restrict reads: a Codex worker can still read credential files that every
  other provider is denied. What contains a secret it reads is the controller: `report.py`'s
  secret scan on the posted report and the pre-push scan of commit messages and added lines.
  Like Agy, it relies on the pushurl override and controller-only publication that already apply
  to every provider, not on a translated rule list. The exemption holds only for
  `CODEX_SANDBOX_MODE` set to `workspace-write` (the default) or `read-only`; any other value,
  such as `danger-full-access`, gives the worker network and unrestricted writes with no rule
  list, and is outside this decision.
- **Timing.** `expected_deadline_at` is seeded at `AGENT_POOL_DEADLINE_SECS` (2700s) until the
  effort baseline exists. `WORKER_TIMEOUT` (default 2400s) must be shorter than the deadline, or
  the tick refuses to start. A provider timeout with no marker requeues to `agent:ready`, never
  `agent:needs-human`. agy has no inner timeout and `--print-timeout 0`.

### Built so far (on `feature/agent-pool-core`)

`bin/prod-common.sh` (the controller tick: reconcile, claim, run, publish, verify, release),
`scripts/claim-record.py`, `scripts/policy.py`, `scripts/cooldown.py`, `scripts/classify.py`,
`scripts/report.py`, `scripts/render-prompt.py`, `scripts/poolstate.py`, and the offline tests
`tests/verify-lease.sh` (unit) and `tests/verify-providers.sh` (end-to-end, stub CLIs).

**Not built yet:** the thin `prod-<provider>.sh` entrypoints, `doctor.sh`, `mailbox.py`,
`effort-baseline.py` (the deadline is the seed only), the cooldown recovery probe, and the
systemd units and installer. Until the doctor exists, each tick does the reconciliation itself:
a stale claim found under the job lock is requeued and its provider cooled down.

**Open questions:** Agy has no deny list, so an auto-approved Agy resolve relies on the
pushurl override and controller publication alone. Codex's `workspace-write` sandbox has no
network, so its adapter reads fail and it cannot write a report outside the worktree. It falls
back to a final-response report. Gate commands (`npm run`, `just`, `composer`) run repository
code that a resolve worker can edit. Push and publication are still controller-only, but the
gate is not a sandbox. Cursor's `.cursor/cli.json` prefix rules cannot deny an option at an
arbitrary position (`git log -p -n 3 --output=/tmp/x` starts with the allowed `git log`),
redirection, a symlinked path or brace expansion; `policy.py check` denies all of these, but
Cursor's own CLI enforces only the prefixes, so Cursor is not contained by cli.json alone.
D1 is decided: the controller will run gate commands itself from a pinned list after the worker
exits (not built yet). **D2 is decided too (Craig, 2026-10-18): exactly one host runs the pool
against a given repo, for v1.** Claims stay local files; there is no shared claim store and no
plan to add one for now. There are real plans for a second host later — tracked separately in
issue #5 ("Plan to plan: multi-host support for the agent pool") rather than designed here, so
this PR isn't blocked waiting on that design. Once `doctor.sh` exists, it should refuse to run
against a repo another `AGENT_POOL_STATE`/host is already active on, rather than silently
double-claiming; not built yet, so there is nothing to enforce this today.

Resolve workers must not run unattended until the controller-gates follow-up (branch
docs/controller-gates-plan, docs/plans/controller-gates.md) lands.

## What already exists and gets reused, not rebuilt

- **`skills/pr-loops-common/gitea-pr.py`** — the Gitea adapter (list/label/comment). The new
  pool calls this directly; no second Gitea client.
- **`skills/pr-loops-common/pr-merge.sh`** — the shape precedent for the doctor: ~150 lines of
  plain bash, zero LLM calls, `flock`, trap-based cleanup, label-based claim/release. The
  doctor's bash driver should look like this, not like a review/resolve worker.
- **`~/.codex/skills/tmux-multi-pipeline/lease.py`** — a complete, already-correct Python
  implementation of atomic lease mechanics. Reuse directly:
  - `save()` — `tempfile.mkstemp` same-dir → write+flush+fsync → `os.replace` → fsync the
    parent dir fd too. Crash-safe; copy verbatim into the new claim/cooldown writers.
  - The `.lock`-sibling + `fcntl.flock(LOCK_EX)` pattern, scoped per-job instead of globally.
  - `eligible()`'s selection algorithm (first-in-order, not self, not retired, available,
    cooldown passed) — same shape, adapted so the roster is "providers enabled for this job
    type" and cooldowns are doctor-populated rather than self-reported.
  - **The epoch-fencing pattern** (`lease.py`'s `epoch` field plus its "stale orchestrator;
    stop sending" check on every write) — this is the direct fix for the review's ownership
    finding. The job-claim design below adapts it as a per-claim `attempt_id`: the same idea
    `lease.py` uses to stop a superseded dispatcher from acting, applied to a superseded job
    worker instead.

  **Not reusable as-is:** `lease.py`'s staleness model requires the holder to call
  `renew`/`limited` itself — exactly the capability a silently-dead worker doesn't have. The new
  design (below) does not depend on self-reported renewal at all, which is the core fix.
- **Systemd conventions** (confirmed from 20 existing timers): `Type=oneshot` + `OnCalendar`
  (never `OnUnitActiveSec`) + `Persistent=true` + `RandomizedDelaySec`; PATH set both in the
  unit's `Environment=` *and* redundantly inside the invoked script (this box has repeatedly hit
  the non-interactive-shell PATH trap — belt-and-suspenders is the established, deliberate
  pattern, not redundancy to trim).
- **`~/.local/bin/remote-claude-task <repo> <prompt-file>`** — existing precedent for reading a
  prompt from a mutable file; never previously wired to a `.timer`, which is the new piece.

## New layout (inside the existing repo, sibling to `skills/`)

```
agent-pool/
  bin/
    prod-common.sh       # shared reconcile -> claim -> invoke -> publish -> verify -> release; provider-parameterized
    prod-claude.sh       # thin entrypoint, sources prod-common.sh (not built yet)
    prod-codex.sh        # (not built yet)
    doctor.sh            # zero-LLM driver; uses deterministic helpers, systemctl and git/Gitea; optional retalk (not built yet)
  scripts/
    claim-record.py      # atomic per-job claim file; attempt_id fencing; reconciliation (see below)
    policy.py            # the one worker permission allowlist, translated per provider CLI
    cooldown.py          # cooldown-gated eligible selection and the single place cooldowns and setup faults are written
    classify.py          # provider run -> ok | setup | limit | timeout | incomplete
    report.py            # validates a worker's report marker before the controller publishes it
    render-prompt.py     # literal placeholder substitution for prompt templates
    poolstate.py         # atomic writes, flock, state dir, injectable clock
    mailbox.py           # atomic enqueue/pending/ack; stable worker IDs and message IDs (not built yet)
    effort-baseline.py   # parses pool.log -> rolling avg per provider; seeds at 2700s (not built yet)
  prompts/
    claim-job.txt         # default "go claim a job" template
    reassigned.txt         # "your task was reassigned, go pick a new one" template
  systemd/
    prod-claude.{timer,service}
    prod-codex.{timer,service}
    doctor.{timer,service}
  install_systemd_units.sh   # same idempotent/--force/--list shape as install_skills_and_actions.sh
  docs/HANDOFF-agent-pool.md # state machine + decision log, mirrors HANDOFF-pr-automerge.md
  tests/
    verify-lease.sh          # offline unit tests: claim-record.py fencing/reconciliation/deadline
                              # boundary, holds, cooldowns, classification, prompt rendering, policy
    verify-providers.sh      # offline end-to-end ticks against stub CLIs, a stub Gitea adapter and
                              # a local bare remote: publication, fencing, reconciliation, adapters
    inject-staleness.sh      # doctor scenarios, see Verification (not built yet)
```

The shared prompts live in `skills/pr-loops-common/prompts/review.generic.txt` and
`resolve.generic.txt`, not under `agent-pool/prompts/`.

Runtime state (not checked in), `~/.local/state/agent-pool/`:
`pool.log` (same `date -Is [MODE] msg` format as `pr-loop.log`, keyed by `repo#issue` **and**
`attempt_id` — see below), `claims/<repo>__<issue>.json`,
`mailboxes/<worker_id>/<message_id>.json`, `cooldowns.json`, `doctor.log`,
`prod-<provider>.log`. Prompt templates remain static; per-launch prompts are rendered
from templates plus pending notices. Worker IDs are configured explicitly and stable
across restarts; multiple workers using one provider have separate mailboxes.

## The claim / staleness / handoff design

**Core decision: a write-once claim record, never renewed, staleness purely derived.** A
renewed-heartbeat lease (`lease.py`'s model) requires the holder to still be alive enough to
call `renew` — precisely what a silently-dead worker can't do, which is the entire lesson of
today's incident. This part of the original design held up under adversarial review. Four
things around it did not and are revised here: the deadline comparison double-counted a
timestamp, there was no fencing against a superseded worker still acting, there was no
reconciliation rule for a crash between the local-file write and the Gitea label write, and the
terminal-log check wasn't scoped to one attempt. All four are fixed by the same two additions:
an **`attempt_id`** on every claim, log line, and completion check, and a **label-is-authoritative
reconciliation rule** that makes every partial-crash state self-healing on the next tick.

### Claim record (v2 schema)

```json
{
  "version": 2, "repo_slug": "...", "issue_number": 42, "provider": "claude",
  "worker_id": "ubuntu-claude-1",
  "attempt_id": "<uuid4>", "branch": "...", "worktree": "...",
  "claimed_at": "2026-10-16T09:00:00Z",
  "expected_deadline_at": "2026-10-16T09:45:00Z"
}
```

`expected_deadline_at` is **always an absolute timestamp**, computed once at claim time
(`claimed_at + max(seed, avg * multiplier)` — see Effort baseline below) and never recomputed
or added to again. The original draft defined it this way in the effort-baseline paragraph but
then wrote the staleness check as `now > claimed_at + expected_deadline_at`, silently adding
`claimed_at` a second time — in practice this pushes the real deadline out by another
`claimed_at`-sized number of seconds (a Unix timestamp, so effectively "never"). **The staleness
check is simply `now > expected_deadline_at`.** `claim-record.py`'s tests assert this at the
boundary: one tick before expiry, exactly at expiry, one tick after, with a fixed/injected clock
— not just "eventually triggers."

### Ownership fencing

Every claim gets a fresh `attempt_id` (uuid4, no persistent per-job counter needed since records
are deleted on release). Two things key off it:

- **The EXIT/TERM trap in `prod-common.sh` re-reads the claim record before acting**, and only
  releases/relabels if the `attempt_id` it captured at claim time still matches what's on disk.
  If it doesn't match, the doctor already reassigned this job to someone else; the trap logs
  "attempt superseded, no-op" and exits touching nothing. This is what stops a slow worker, or
  one still mid-shutdown, from releasing (or worse, completing and publishing against) a
  replacement's claim.
- **The doctor stops the stale systemd unit before (or concurrently with) writing the new
  attempt.** Each prod is one oneshot unit instance, so `systemctl --user is-active
  prod-<provider>.service` tells the doctor if that attempt's process might still be running;
  if so, `systemctl --user stop` sends it a real termination signal rather than assuming elapsed
  time means it's gone. Correctness does not depend on getting this ordering exactly right —
  fencing is what makes it race-safe either way, because the trap's own stale-attempt check
  fires regardless of whether the stop or the new-attempt write happened first. Stopping the
  unit is still done, as a bound on how long a straggler can keep running, not as the
  correctness mechanism itself.

### Reconciliation (crash-safety between the local record and the Gitea label)

**The Gitea label is authoritative; the local claim record is a cache that must tolerate being
stale, missing, or orphaned.** Ordering: claim writes the record first, *then* flips the label;
release flips the label first, *then* deletes the record. Every read (by `prod-common.sh` before
claiming, and by `doctor.sh` on every tick) reconciles before trusting either side:

| Label | Record | Meaning | Action |
|---|---|---|---|
| `agent:claimed` | matching record exists | normal | proceed with staleness check |
| `agent:claimed` | no record (or unreadable) | crashed after label flip, before/during record write | no deadline can be computed — do **not** guess; route straight to `agent:needs-human` |
| `agent:ready` (or anything else) | record still exists | crashed after label flip, before record delete — release already succeeded | delete the orphaned record, no further action |

This directly answers the review's finding: there is no state a crash can leave behind that
isn't resolved by one of these three rows on the next tick, by either `prod-common.sh` or
`doctor.sh`, whichever reads it first.

### The doctor's full tick, end to end

Pulling the pieces above together into one sequence, since the fencing and reconciliation
detail above shouldn't obscure it: on each 5-minute tick, for every claim record found —

1. Reconcile label vs. record (table above); skip jobs that are already consistent and not
   expired.
2. For a genuinely stale `agent:claimed` job (expired deadline, matching record, no
   terminal line for this `attempt_id`): under the job lock, persist an idempotent
   reassignment notice for its `worker_id` before removing recovery evidence. Stop
   the stale unit if active and inspect the worktree read-only. Record its location
   and observed WIP in the notice; record provider cooldown; relabel to `agent:ready`
   and delete the matching claim. The notice records recovery progress so the next
   doctor tick can finish an interrupted transition, even after claim deletion.
   Only completed reassignments become deliverable. Optionally send a copy through
   retalk; missing identity, missing CLI or delivery failure is logged and never
   blocks recovery. Do not overwrite or consume a mutable provider prompt file.
3. For the `agent:claimed`-with-no-record row: relabel straight to `agent:needs-human` instead —
   there's no deadline to evaluate, so no automatic decision is safe here.

### Attempt-scoped logging (fixes the "old terminal line blocks new recovery" finding)

Every `pool.log` line — spawned and terminal alike — carries `attempt_id`, not just
`repo#issue`. The doctor's staleness check looks for a terminal line matching **the current
claim's specific `attempt_id`**, not "any terminal line ever logged for this job." Without this,
a job whose first attempt failed loudly (logged, requeued) and whose second attempt then died
silently would be wrongly treated as already resolved, because the first attempt's terminal
line was still sitting in the log — exactly the review's finding.

### Fast path, now with classification (fixes the "bypasses the only cooldown" finding)

`prod-common.sh`'s EXIT trap (described above as the fast path — still the thing that catches
the ~32-second credit-wall case in seconds, without the doctor) must **classify the failure
before releasing**, not just release-and-log:

1. Capture the invoked CLI's exit code and output.
2. Check it against a small set of known provider-exhaustion signatures (the literal
   "Credit balance too low" text, an HTTP 429, other recognized quota/auth error strings —
   necessarily incomplete; unclassifiable failures just skip this and behave as before).
3. On a classified provider-level failure, call `scripts/record-cooldown.py` — the **same**
   helper the doctor calls — before relabeling to `agent:ready`, with an increasing backoff
   tracked per provider in `cooldowns.json` on repeated classified failures.
4. Each provider's service, before attempting a real claim, checks whether it's currently in
   its own cooldown window; if so it runs a cheap recovery probe first (the `<cli> -p "say OK"`
   pattern already proven working for Claude/Codex/Agy this session) and skips claiming
   entirely this tick if the probe itself fails — rather than claiming a real job and
   immediately failing it the same way again.

Without this, the exact motivating failure (a 32-second credit-wall death) would keep
re-claiming and re-failing on every subsequent hourly prod forever, since the fast path was
the first thing to see it and never told the cooldown system — the doctor's cooldown mechanism
alone only covers *silent* (undetected-by-the-worker-itself) failures, not fast, self-detected
ones.

### Durable mailbox and return-from-sick

`mailbox.py` reuses same-directory atomic writes, fsync and advisory locks. Each notice
contains `message_id`, `worker_id`, provider, repository, issue, superseded `attempt_id`,
reason, worktree/branch references, creation time, recovery progress, and acknowledgment
state. Enqueue is idempotent by worker + repository + issue + attempt + event kind.
Pending notices are delivered oldest first; acknowledgments name exact message IDs.
Acknowledged records remain available for audit. Read, render and spawn never delete them.

Before invoking any provider, `prod-common.sh` reads that worker's pending completed
notices and includes them in the normal prompt. Claude, Codex, Cursor, Agy and Grok use
this same interface; only their CLI adapters differ. No native plugin, live session
injection, retalk identity or model call is required to store or retrieve notices.
A cooldown-skipped tick leaves them pending.

The agent returns a structured receipt naming the supplied message IDs. The launcher
validates it against this invocation's worker ID and supplied notices, then atomically
acknowledges those IDs. Process startup or exit zero alone is not acknowledgment.
Failed startup, missing/invalid receipt, or a crash before acknowledgment leaves notices
pending for the next launch. Delivery is at least once: repeated message IDs must be
harmless, including a crash after receipt but before acknowledgment. Receipt confirms
reported acceptance, not proof of comprehension or job completion.

Messages are informational. Ownership must be checked under the job lock at every
controller-mediated completion, release and publication boundary. A superseded attempt
cannot publish simply because it missed its notice; provider workers must not bypass
those guarded publication paths. Late traps remain no-ops. Retalk is an optional copy
for conversation/cross-machine notifications, never authority to claim or complete work.
V1 mailboxes are local to the single pool host; distributed ownership is deferred.

**Effort baseline ("scrum effort"):** `effort-baseline.py` parses `pool.log`'s paired
spawned/terminal lines per provider (now attempt-scoped — see above), rolling average over the
last 20 samples, trusted only after 5+ samples exist. This produces the one number written into
the claim record as `expected_deadline_at` = `claimed_at + max(2700s seed, avg * 2.5)`, computed
once, at claim time — not the raw average, which would flag roughly half of all legitimately
still-working jobs as stale. The 2.5x safety multiplier is a starting default that needs real
data to tune, not a final answer. Scoped per-provider only for v1 (no per-job-type breakdown yet
— this queue has no job-type taxonomy the way review/resolve/merge already do).

## Systemd units

Matching the confirmed convention exactly. Staggered offsets so Claude/Codex prods don't
contend with the existing `:08/:23/:38/:53` merge-tick or `:37` pipeline tick:

```ini
# prod-claude.timer
[Timer]
OnCalendar=*-*-* *:05:00
Persistent=true
RandomizedDelaySec=120
```
```ini
# prod-claude.service
[Service]
Type=oneshot
Environment=PATH=/usr/local/bin:/usr/bin:/bin:/home/craigpar/.local/bin:/home/craigpar/.npm-global/bin
ExecStart=/home/craigpar/.local/bin/prod-claude.sh
TimeoutStartSec=2700
StandardOutput=append:/home/craigpar/.local/state/agent-pool/prod-claude.log
StandardError=append:/home/craigpar/.local/state/agent-pool/prod-claude.log
```
`prod-codex.timer` at `*:15:00`. `doctor.timer` at `*:0/5:00` (5-minute cadence, not hourly),
`AccuracySec=30s`, `TimeoutStartSec=120`. `doctor.service`'s `ExecStart` must never invoke
`claude`/`codex`/any LLM CLI — only deterministic Python/shell helpers, `systemctl`, `git`, `gitea-pr.py`, `tea`, and optional `retalk` — this is the literal
mechanism by which it can't itself be rate-limited.

## Prerequisites (block parts of this, don't block starting)

- **Immediate, before any new build:** relabel the ~12 audit-identified PRs to
  `review:requested` for a real re-review (separate small action, not part of this plan's
  build).
- **Blocks Agy/Grok/Cursor specifically, not Claude/Codex:** confirm Grok's actual non-interactive invocation shape (never
  tested this session, only referenced secondhand); confirm Cursor's edit-capable headless mode
  (only its read-only `ask` mode was tested); confirm Agy's auth state (subscription vs.
  pay-per-token — user said they'd check, not yet confirmed).
- **Optional notifications:** agent-talk identities are not a prerequisite for any provider.
- **Doesn't block anything, but worth deciding before `doctor.sh`'s worktree inspection grows
  teeth:** whether a stalled job's uncommitted WIP should be mechanically rescued (plain
  `git commit`+push to a rescue branch, no LLM) before releasing the claim. Read-only inspection
  only for this first pass; rescue-commit is a natural, explicitly deferred v2.

## Phasing

- **Phase 0** (now): relabel the audited PRs; nothing else below depends on this.
- **Phase 1**: `claim-record.py`, `mailbox.py`, `effort-baseline.py` (seed-only), the `agent:*` labels,
  `prod-common.sh` + `prod-claude.sh` + `prod-codex.sh`, their timer/service pairs, `pool.log`.
  Run a day or two against a low-stakes test repo to accumulate real duration history before
  trusting the computed average over the seed.
- **Phase 2**: `doctor.sh`, proven via the synthetic tests below (unit-level and end-to-end)
  *before* ever depending on a real rate-limit event occurring naturally.
- **Phase 3**: Agy/Grok/Cursor, one at a time, each only once its own prerequisite gap closes.
- **Phase 4** (separate, later, already agreed): port into `TheGiteaCodeFactory`.

## Verification

Two test files, both fully offline and deterministic — no waiting hours for a real rate limit,
and no dependency on scenario order.

### `agent-pool/tests/verify-lease.sh` — unit-level, pure logic

(Planned as `verify-claim-record.sh`; built as `verify-lease.sh`, which also covers cooldowns,
classification, prompt rendering and the permission policy.)

Mirrors `pr-loops-common/tests/verify-merge.sh`'s style: direct calls into `claim-record.py`
with a fixed/injected clock, no systemd, no real Gitea calls (a stub adapter). Covers the
reconciliation table exhaustively — one case per row, plus the fencing check (an `attempt_id`
mismatch is rejected) and the staleness boundary (one tick before/at/after
`expected_deadline_at`, asserting no double-counting regression).

### `agent-pool/tests/inject-staleness.sh` — offline synthetic end-to-end scenarios

**Scenario 1 — the original silent-death case.** Label a disposable test issue `agent:ready`.
Claim it with an injectable `AGENT_POOL_FAKE_DEADLINE_OFFSET` forcing `expected_deadline_at`
into the past, relabel to `agent:claimed`, then deliberately exit without invoking any CLI and
without the trap running (simulating `kill -9`) — "went dark with no self-release." Fire
`doctor.sh` once by hand and assert: staleness detected; stale systemd unit check attempted;
worktree inspected without crashing; durable notice recorded for the correct worker;
relabeled back to `agent:ready`; claim record deleted; cooldown recorded. Assert this
works with retalk absent. Fire `prod-claude.sh`: its rendered prompt includes the pending
notice, which remains pending until a valid acknowledgment receipt is recorded.
Clean up the disposable issue.

**Scenario 2 — concurrent completion vs. reassignment (ownership fencing).** Claim a job,
capture its `attempt_id`. Force the deadline into the past and fire `doctor.sh` to requeue it, then let a replacement worker acquire a
new claim (new `attempt_id`). *Then*, simulate the original attempt's EXIT trap
firing late, using its stale captured `attempt_id`. Assert: the trap's re-read sees a mismatch
and no-ops (does not relabel, does not delete the new claim record, does not touch
`cooldowns.json`); the doctor's reassignment is the one that stands.

**Scenario 3 — partial Gitea failures.** (a) Mock the claim path so the local record write
succeeds but the simulated Gitea label call fails/times out. Assert the next tick's
reconciliation (the `agent:claimed`-with-no-record... — here inverted: record exists, label
never flipped from `agent:ready`) is recognized as an abandoned claim attempt and cleaned up,
not left stuck or double-claimed by a second worker. (b) Mock the release path so the label
flip to `agent:ready` succeeds but the simulated record deletion fails. Assert the next tick
recognizes the orphaned record (label says ready, record still present) and deletes it per the
reconciliation table, without re-triggering a handoff for an already-released job.

**Scenario 4 — repeated attempts, same job.** Claim and fail attempt 1 loudly (a real logged
terminal fail line with attempt 1's `attempt_id`), let it requeue normally. Claim again
(attempt 2, same `repo#issue`, new `attempt_id`), then let attempt 2 die silently (same as
scenario 1). Assert the doctor's staleness detection for attempt 2 fires — i.e. is *not*
short-circuited by attempt 1's old terminal log line still being present — proving the
attempt-scoping fix, not just asserting the end state.

**Scenario 5 — immediate provider rejection (fast-path classification).** Simulate the EXIT
trap seeing a classified failure signature (inject a fake "Credit balance too low" string into
the captured output) on a fresh claim. Assert: `record-cooldown.py` is called immediately from
the trap itself, before the doctor ever ticks; `cooldowns.json` reflects it. Then simulate that
same provider's *next* prod firing while the cooldown is still active: assert its recovery probe
runs first, the probe is made to fail too, and the service skips claiming entirely for that
tick (no job touched, no second failure logged) — rather than claiming a real job and
immediately failing it the same way again.

**Scenario 6 — mailbox delivery and crash recovery.** Use stub provider adapters for all
five providers. Assert identical notice delivery without retalk or native inbox hooks;
failed spawn and missing/invalid receipt retain notices; valid receipt acknowledges only
supplied IDs. Crash after receipt before ack and verify safe redelivery. Two workers with
the same provider must never read or acknowledge each other's notices. Repeated doctor
ticks enqueue one notice per attempt. Inject crashes before/after label release and claim
deletion: recovery progress remains durable and unfinished notices are not delivered as
completed reassignments. Optional retalk failure never prevents local recovery. Verify
superseded attempts cannot complete or publish even without reading a notice.

Also build `DOCTOR_DRY_RUN=1` (mirroring `pr-loop.sh`'s `DRY_RUN`) so the doctor can run in
observation-only mode against real current claims for a while before being trusted to execute
real reassignments, and a per-repo allowlist (mirroring `pr-merge.sh`'s
`PR_MERGE_ALLOW_REPOS`) gating real (non-dry) reassignment, not just real merging.

## Critical files to read again at implementation time

- `/tmp/pr-loop-skills/skills/pr-loops-common/pr-loop.sh` — claim/spawn/verify/finish pattern
- `/tmp/pr-loop-skills/skills/pr-loops-common/pr-merge.sh` — doctor's bash-driver shape
- `/tmp/pr-loop-skills/skills/pr-loops-common/gitea-pr.py` — the adapter to reuse
- `~/.codex/skills/tmux-multi-pipeline/lease.py` — atomic-write + `eligible()` to adapt
- `/home/craigpar/.local/bin/pr-pipeline.sh`, `pr-merge-tick.sh` — already-running automation,
  now confirmed to be what ran on the stale key for nine-plus days
