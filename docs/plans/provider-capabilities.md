# Provider capability model

Status: design plan, decisions settled 2026-10-20 (see Section 9), reconciled against master on 2026-10-21
(not rebased) for the per-repo abilities model and `doctor.sh` that PR #19 and PR #21 already
merged (Section 9, decision 10). Written against `master` at `e92b7c8` (which includes merged
PRs #2, #11, #13, #15, #17, #19, and #21), `docs/plans/agent-pool-worker-pool.md`,
`docs/plans/controller-gates.md`, and `docs/plans/controller-commits-everything.md` (split out
of this plan's former Section 7 — see Section 9's decision on scope).

## Context and motivation

Today `agent-pool/bin/prod-common.sh` models only two job kinds (`review` and `resolve`, plus `settled` which runs no provider) and hardcodes provider eligibility in `job_providers()` in `agent-pool/bin/prod-common.sh` with a single special case: `agy` is skipped for `resolve` unless `AGY_AUTO_APPROVE=1` is set. `~/.config/agent-pool/repos.toml` already grants each repo a per-provider `AGENT_POOL_ABILITIES` list (read by `agent-pool/scripts/repoconfig.py`, consumed by `prod-<provider>.sh`), and `agent-pool/bin/doctor.sh`/`agent-pool/scripts/doctor.py` already escalate an `agent:ready` job to `agent:needs-human` when no roster provider in `repos.toml` has the needed ability enabled on that repo. That existing machinery answers one question only: *which providers is this repo allowed to use at all, and for which of the five ability names.* It says nothing about a provider's *own* abilities independent of any repo, or about a single job declaring which abilities it specifically needs (`requires`) versus the coarser five-name list a repo grants wholesale. Meanwhile:

1. `docs/plans/controller-gates.md` moves gate execution out of workers into a controller-owned bubblewrap sandbox (`agent-pool/scripts/gates.py` reading `.agent-pool/gates.toml`), strips keys and ambient credentials from workers, and removes `agy` from `resolve` permanently because `--dangerously-skip-permissions` violates the no-keys invariant.
2. PR #19 (merged) added `scripts/tools/night_shift.sh` so TheNightCrew can dispatch `cursor` on repository issues using `policy.py cursor-json --job resolve`, noting that test execution inside the worker remains a temporary residual risk until controller-run gates land; PR #21 (merged) added `agent-pool/bin/doctor.sh`, `agent-pool/scripts/doctor.py`, `agent-pool/scripts/repoconfig.py`, `repos.toml`, and `skills/pr-loops-common/gitea-labels.py`'s `agent:*` labels — all without capability-awareness, since `capabilities.py` (this plan) doesn't exist yet.
3. Different tasks require different trust boundaries and publication contracts: writing a design plan, reviewing a diff, building a throwaway prototype, authoring tests without touching production code, and resolving findings on a branch.

Borrowing the capability-and-requirement model from Atlassian Bamboo, each provider worker advertises a set of **abilities**, each queued job declares its **required abilities** (`requires`), and a worker only claims or falls back onto a job when its available abilities satisfy every requirement on the job.

---

## 1. Ability vocabulary

Every job processed by `agent-pool/bin/prod-common.sh` (and issue-dispatched jobs routed through `scripts/tools/night_shift.sh`) uses a closed vocabulary of five abilities. Under the **controller-commits-everything** rule (`docs/plans/controller-commits-everything.md`, a separate prerequisite plan for `prototype` and `test-author`; `resolve` migrates onto it too but keeps today's worker-commits-locally mechanism until that plan lands), no worker ever runs `git add`, `git commit`, `git push`, or any gate command.

| Ability | Worker read scope | Worker write scope | Controller gates run? | Controller commits and pushes? | Output artifact on Gitea |
|---|---|---|---|---|---|
| `plan` | Worktree files, `.agent-pool-context.md`, read-only git (`status`, `diff`, `log`, `show`) | Report file only (`$AGENT_POOL_STATE/runs/report-<tag>.md`) | No | No (worktree must remain clean) | Plan comment carrying `<!-- pulse-plan:v1 head=<sha> -->` |
| `review` | Same as `plan` | Report file only | No (optional pre-review gate context in `.agent-pool-context.md`) | No (worktree must remain clean) | Review comment carrying `<!-- pulse-review:v1 head=<sha> findings=<n> -->` |
| `prototype` | Same as `plan` | Worktree files (excluding protected and tool-config paths) plus report file | Optional (informational receipt only; red gate does not discard the prototype) | Commits to a local controller ref (`refs/agent-pool/prototypes/<pr>/<attempt_id>`); **never pushed** to `origin` unless promoted | Comment with diffstat, sanitized patch block, and `<!-- pulse-prototype:v1 base=<sha> commit=<proto_sha> attempt=<attempt_id> files=<n> -->` |
| `test-author` | Same as `plan` | Test paths only (matched against `test_paths` in `.agent-pool/gates.toml`) plus report file | Yes, mandatory (`agent-pool/scripts/gates.py run` in sandbox) | Yes: controller creates a signed commit and fast-forward pushes `refs/heads/<headref>` if gates match expectation | Comment with gate section and `<!-- pulse-test-author:v1 head=<newhead> base=<sha> tests_changed=<n> -->` |
| `resolve` | Same as `plan` | Worktree files (excluding `.agent-pool/gates.toml`, lockfiles, `protect` list, and tool configs) plus report file | Yes, mandatory (`agent-pool/scripts/gates.py run` in sandbox) | Yes: controller creates a signed commit and fast-forward pushes `refs/heads/<headref>` only when gates pass | Comment with gate section and `<!-- pulse-resolve:v1 head=<newhead> reviewed=<rhead> fixed=<n> noted=<n> deferred=<n> -->` |

### Detailed semantics per ability

1. **`plan`**:
   - Produces an architectural or implementation plan for an issue or PR without altering repository files.
   - If the worker modifies any tracked or untracked file inside `$JOB_WT`, the controller discards the worktree changes and fails verification if the report is missing.
2. **`review`**:
   - Preserves the existing contract in `agent-pool/bin/prod-common.sh` and `skills/pr-loops-common/marker.py`.
   - Reads the PR diff, commit history, comments, and unresolved review threads from `.agent-pool-context.md` (`write_context()` in `agent-pool/bin/prod-common.sh`) and read-only tools, then writes the review report.
3. **`prototype`**:
   - Executes in a detached throwaway worktree created by `prepare_worktree()` in `agent-pool/bin/prod-common.sh`.
   - Gives the worker full worktree edit capability (subject to protected-file and secret checks) to explore a spike or alternative implementation.
   - The controller never pushes a `prototype` result to `origin/<headref>`. Instead, it records a signed commit under a local controller-only ref in `$AGENT_POOL_MAIN`, posts the sanitized diff and report to Gitea, and deletes the worktree in `end_job()`. Promotion to a real branch requires an explicit human action (`agent:promote`, Section 7; signing mechanics in `docs/plans/controller-commits-everything.md`).
4. **`test-author`**:
   - Separates test creation from implementation so one provider (including `agy`) can write unit or integration tests while the controller executes them in the bubblewrap sandbox defined in `docs/plans/controller-gates.md`.
   - The worker may only create or edit files matching the repository's `test_paths` globs (defaulting to `tests/**`, `**/tests/**`, `**/*.test.*`, `**/*.spec.*`, `*Test.cs`, `*Test.php`, and `**/verify-*.sh`, minus any path in `protect`). Touching any non-test path causes `publish()` to reject the run and transition to `agent:needs-human`.
5. **`resolve`**:
   - Addresses findings from the latest `pulse-review:v1` marker (or implements an approved issue spec when invoked via the issue executor flow).
   - The worker edits files in `$JOB_WT` and writes its disposition report. It does not stage, commit, run gates, or push; the controller runs gates, creates the signed commit with trailers, stamps the resulting commit SHA into the marker, and pushes through `claim-record.py guard`. This mechanism is `docs/plans/controller-commits-everything.md`'s; until that plan lands, `resolve` keeps today's existing worker-commits-locally/controller-pushes-only behavior unchanged.

---

## 2. Per-provider capability manifest

Capabilities are defined in a new helper `agent-pool/scripts/capabilities.py`, which becomes the single owner of the per-provider ceiling (static defaults, `agy` minus `resolve`) plus new optional per-host narrowing via `AGENT_POOL_CEILING_<PROVIDER>` (named apart from `repos.toml`'s existing per-repo `AGENT_POOL_ABILITIES` — see "Relationship to `repos.toml`" below). An operator env var can **narrow** a provider's advertised abilities (for example `AGENT_POOL_CEILING_GROK=review,plan`), but can never **widen** a provider beyond its hard ceiling in `capabilities.py` (in particular, `agy` can never be granted `resolve`).

### Relationship to `repos.toml`'s existing `AGENT_POOL_ABILITIES` and `CEILING` (extends, does not replace)

`repos.toml` and `capabilities.py` answer different questions and both must pass for a claim:

- **`repos.toml`'s `AGENT_POOL_ABILITIES`** (existing, unchanged by this plan): per-**repo**, per-provider authorization — which of the five ability names a given repo's operator has chosen to let a given provider run there at all. Read by `agent-pool/scripts/repoconfig.py`, set into the tick's environment by `prod-<provider>.sh`. This stays the first gate; this plan does not touch it.
- **The per-provider ceiling** (existing on master as `repoconfig.CEILING`, a static `{provider: set(abilities)}` dict with no operator narrowing — `agy` already drops `resolve` there today): this plan does not duplicate it as a second hardcoded table. `capabilities.py` becomes its one owner; `repoconfig.py`'s local `CEILING` dict and its two use sites (`abilities()`'s `granted &= CEILING[provider]`, and the config-load warning when a provider table over-grants an ability) are replaced with a call to `capabilities.py`'s static hard ceiling only: an imported `capabilities.ceiling(provider)` (or a `capabilities.py ceiling --provider P` subcommand if shelling out is preferred), which applies no `AGENT_POOL_CEILING_<PROVIDER>` narrowing. `repoconfig.py` never calls the env-narrowed `abilities --provider P`, so `repoconfig.abilities()`, the config-load warning, `REPO_ROSTER` and `doctor.py` do not depend on any host's `AGENT_POOL_CEILING_*` environment. `capabilities.py`'s only addition over today's `repoconfig.CEILING` is the optional `AGENT_POOL_CEILING_<PROVIDER>` operator narrowing — the hard floor (`agy` never `resolve`) is unchanged, just read from one place instead of two that could silently drift apart.
- **`capabilities.py`'s `requires`/`match`** (new, this plan): per-**job** routing — which specific provider among those already authorized by both layers above should claim *this* job, based on what the job itself declares it needs.

A provider claims a job only when all three pass: the repo's `AGENT_POOL_ABILITIES` includes the job's ability, the provider's host-wide ceiling (now sourced from `capabilities.py` alone) includes it too, and `set(job.requires) <= set(capabilities.py abilities(provider))`. `capable_providers()` (Step 3) checks all three; it does not shadow or duplicate `repos.toml`'s existing per-repo check, it runs after it.

### Capability matrix

| Provider | `plan` | `review` | `prototype` | `test-author` | `resolve` | Containment & invocation mechanism (`agent-pool/bin/prod-common.sh` & `agent-pool/scripts/policy.py`) |
|---|---|---|---|---|---|---|
| `claude` | Yes | Yes | Yes | Yes | Yes | `claude -p --output-format json --model <model> --permission-mode default`, scoped `--add-dir`, `--allowedTools` / `--disallowedTools`, PreToolUse hook (`policy.py hook-settings` -> `policy.py hook`), PATH `git` shim |
| `codex` | Yes | Yes | Yes | Yes | Yes | `codex exec --ephemeral --sandbox <mode> --model <model> --cd <wt> -` (`read-only` for `plan`/`review`; `workspace-write` for `prototype`/`test-author`/`resolve`); no network inside sandbox; stays out of default `PROVIDER_ORDER` unless listed |
| `cursor` | Yes | Yes | Yes | Yes | Yes | `cursor-agent -p --trust --workspace <wt> --output-format stream-json --model <model>` (never `--force`); per-worktree `.cursor/cli.json` (`policy.py cursor-json`), optional `.cursor/hooks.json`, PATH `git` shim |
| `grok` | Yes | Yes | Yes | Yes | Yes | `grok --cwd <wt> --prompt-file <prompt> --output-format json --permission-mode dontAsk -m <model>`, per-ability `--allow` and `--deny` rules from `policy.py`, PATH `git` shim |
| `agy` | Yes | Yes | Yes | Yes | **No** | `agy -p <prompt> --output-format json --print-timeout 0 --mode plan`; never uses `--dangerously-skip-permissions` |

### Why `agy` has `plan`, `review`, `prototype`, `test-author` and NO `resolve`

- **Why `resolve` is forbidden for `agy`**: In `agent-pool/bin/prod-common.sh` (lines 95, 237, 312), `agy` could previously take `resolve` jobs only when `AGY_AUTO_APPROVE=1` added `--dangerously-skip-permissions`. As Craig confirmed and `docs/plans/controller-gates.md` (Section 5) records, `--dangerously-skip-permissions` lets the worker run arbitrary shell commands without an allowlist or hook, breaking the no-keys / no-code-execution containment invariant. `AGY_AUTO_APPROVE` is retired (setting it logs a `SETUP FAULT` and exits 2), and `capabilities.py` hard-blocks `agy` from advertising `resolve`.
- **How `agy` executes `plan` and `review`**: `agy` runs in `--mode plan`, where all command execution and file writes are denied by the CLI itself. It reads `.agent-pool-context.md` (pre-populated by `write_context()` in `agent-pool/bin/prod-common.sh`) and emits its markdown report as the JSON `response` field (`agent-pool/scripts/classify.py`, line 175), which `classify.py` writes to `--result-out` for `publish()` to validate and post.
- **How `agy` executes `prototype` and `test-author` without `--dangerously-skip-permissions`** (confirmed by direct empirical test on 2026-10-20 — `agy --mode accept-edits --sandbox` was tried first as a candidate middle ground and rejected: it ran an arbitrary shell command (`touch PWNED.txt` succeeded) despite `--sandbox`'s "terminal restrictions" claim, so `--mode plan` + controller-side patch extraction is confirmed necessary, not merely assumed):
  - `agy` still runs in `--mode plan` (so it never executes shell commands and never needs `--dangerously-skip-permissions`).
  - Its prompt template (`prompts/prototype.agy.txt` and `prompts/test-author.agy.txt`) instructs it to emit its file additions/edits inside a fenced `patch` / unified-diff block (or file-replacement blocks) in its final response alongside its report marker, using the target files pre-included in `.agent-pool-context.md`.
  - After `agy` exits, a controller helper (`report.py extract-patch`) extracts the diff from `$result` and applies it to `$JOB_WT` via `gate_git apply --recount` (checking path containment and `test_paths` for `test-author`).
  - From that point on, the controller handles the worktree identically to any other provider: for `prototype`, it commits to the local prototype ref; for `test-author`, it runs `gates.py run` in the bubblewrap sandbox, creates the signed commit, and pushes if green.

### Per-ability permission translation in `agent-pool/scripts/policy.py`

With controller-run gates (`docs/plans/controller-gates.md`) and controller-created commits (`docs/plans/controller-commits-everything.md`), `policy.py` accepts `--job plan|review|prototype|test-author|resolve`:

- **`plan` and `review`**:
  - Allowed shell: `git status`, `git diff`, `git log`, `git show` with vetted flags in `GIT_SPECS` (`agent-pool/scripts/policy.py`).
  - Allowed native tools: `Read`, `Grep`, `Glob` scoped to `read_roots()` (`$JOB_WT` and the per-job run directory), plus `Write(<report>)`.
  - Denied: all `Edit`/`Write` inside `$JOB_WT`, all `git add`/`git commit`/`git push`.
- **`test-author`**:
  - Everything in `review`, plus `Edit` and `Write` scoped specifically to the repo's `test_paths` globs inside `$JOB_WT` (enforced pre-execution in `policy.py`'s `write_allowed()` for Claude/Cursor hooks and allow-globs for Claude/Cursor/Grok, and post-execution by the controller's diff check in `publish()`).
- **`prototype` and `resolve`**:
  - Everything in `review`, plus `Edit` and `Write` on `$JOB_WT/**`, excluding `.git/**`, `TOOL_CONFIG` (`.cursor/`, `.grok/`, `.claude/`, `.agent-pool-context.md`), `.agent-pool/**`, and all `protect` / lockfile paths from `.agent-pool/gates.toml`.

---

## 3. How jobs declare requirements: `agent:*` labels plus a `requires` field

Jobs declare what abilities they need through two composable mechanisms: Gitea `agent:*` labels and an explicit `requires` list on the job/claim record.

### 3.1 Label vocabulary (`skills/pr-loops-common/gitea-labels.py`)

`gitea-labels.py` currently defines four pool state labels (`agent:ready`, `agent:claimed`, `agent:done`, `agent:needs-human`, lines 50-53). We keep those four state labels unchanged and add optional **ability requirement labels** plus one **promotion action label**:

| Label | Category | Meaning |
|---|---|---|
| `agent:ready` | Queue state | Queued for the agent pool to claim |
| `agent:claimed` | Queue state | An agent-pool worker holds a live claim on this PR/issue |
| `agent:done` | Queue state | The agent pool finished; marker on the head names the result |
| `agent:needs-human` | Queue state | Automation stopped and a human must inspect |
| `agent:plan` | Ability requirement | Job requires `["plan"]` |
| `agent:review` | Ability requirement | Job requires `["review"]` |
| `agent:prototype` | Ability requirement | Job requires `["prototype"]` |
| `agent:test-author` | Ability requirement | Job requires `["test-author"]` |
| `agent:resolve` | Ability requirement | Job requires `["resolve"]` |
| `agent:promote` | Controller action | Promote the latest verified `prototype` commit on this PR/issue into a pushed branch commit after gates pass |

`skills/pr-loops-common/pr-merge.sh` (lines 56-58, 95, 154, 174) is updated to treat `agent:plan`, `agent:review`, `agent:prototype`, `agent:test-author`, `agent:resolve`, and `agent:promote` as blocking while `agent:ready` or `agent:claimed` is present, and to strip any leftover ability labels alongside `agent:ready,agent:claimed,agent:done` when merging or failing a PR.

### 3.2 Deriving `requires` for a candidate job

A job's `requires` field is a sorted, deduplicated list of ability strings (`list[str]`). `derive_job()` in `agent-pool/bin/prod-common.sh` is extended to compute both `DJ` (the primary execution phase) and `DREQUIRES` (comma-separated required abilities) in priority order:

1. **Settled check first**: If the PR carries no unfulfilled ability override and already has a clean `pulse-review:v1` marker at `head_sha` or a verified `pulse-resolve:v1` marker answering the latest review at `head_sha` (with a passing gate receipt per `docs/plans/controller-gates.md`), `DJ=settled` and `DREQUIRES=""` (handled by `controller` without spawning a provider).
2. **Explicit `agent:<ability>` labels on the PR/issue**:
   - Any `agent:plan`, `agent:review`, `agent:prototype`, `agent:test-author`, or `agent:resolve` labels on the PR are collected into `requires`.
   - Multiple ability labels can be combined on a composite job (for example `agent:test-author` + `agent:resolve` means `requires = ["resolve", "test-author"]`: the claiming worker must advertise **both** abilities, or the job is executed as a staged pipeline where `test-author` runs first and strips `agent:test-author` on completion, leaving `agent:resolve` for the next pass; see Section 4.2).
3. **Structured directive in the PR/issue description or latest human comment**:
   - `<!-- agent-pool-job: requires=prototype -->` or `<!-- agent-pool-job: requires=test-author,resolve -->`.
   - Parsed by `agent-pool/scripts/capabilities.py parse-requires`, allowing issue templates or NightCrew dispatches to declare requirements without extra label round-trips.
4. **Default marker-based derivation (existing `derive_job()` behavior when no explicit ability label or directive is present)**:
   - Latest `pulse-review:v1` marker matches `head_sha` and `findings > 0` -> `DJ=resolve`, `requires=["resolve"]`.
   - Anything else -> `DJ=review`, `requires=["review"]`.

### 3.3 The `requires` field in the claim record (`agent-pool/scripts/claim-record.py`)

`new_record()` in `agent-pool/scripts/claim-record.py` adds `"requires"` to the v2 claim JSON under `$AGENT_POOL_STATE/claims/<repo>__<pr>.json`:

```json
{
  "version": 2,
  "repo_slug": "craigpars/AgileMedievalPeasantBoard",
  "issue_number": 42,
  "provider": "claude",
  "worker_id": "host-pool",
  "attempt_id": "<uuid4>",
  "branch": "feature/example",
  "worktree": "<worktree-path>",
  "job": "resolve",
  "requires": ["resolve"],
  "claimed_at": "2026-10-20T14:00:00Z",
  "expected_deadline_at": "2026-10-20T14:55:00Z"
}
```

`claim-record.py claim` accepts `--requires <csv>` (defaulting to `--job` when omitted so existing callers in `agent-pool/tests/verify-lease.sh` remain compatible) and preserves `requires` across `reattempt` calls (`cmd_reattempt()`).

---

## 4. Claim filtering by ability alongside leases, fencing and cooldowns

### 4.1 End-to-end claim filter pipeline

During a tick of `agent-pool/bin/prod-common.sh`, provider selection and claim acquisition combine ability matching with the existing lease, fencing, NightCrew hold, and cooldown rules:

```mermaid
flowchart TD
    A["Candidate PR with agent:ready"] --> B["reconcile_pr & claim hold check"]
    B --> C["derive_job -> DJ, DREQUIRES"]
    C --> D{"DJ == settled?"}
    D -- Yes --> E["Claim as controller & finish_job done"]
    D -- No --> F["capabilities.py match --order REPO_ROSTER --requires DREQUIRES"]
    F --> G{"C_roster empty?<br/>(no provider in roster has abilities)"}
    G -- Yes --> H["Route to agent:needs-human<br/>(unsatisfiable requirement)"]
    G -- No --> I["Narrow to this tick's PROVIDER_ORDER<br/>& filter by setup_faults -> C_configured"]
    I --> J{"C_configured empty?"}
    J -- Yes --> K["Keep agent:ready, log SETUP FAULT (exit 2)"]
    J -- No --> L["Filter by provider + ability cooldowns<br/>& gate infra fault -> C_eligible"]
    L --> M{"C_eligible empty?"}
    M -- Yes --> N["Keep agent:ready, wait for cooldown"]
    M -- No --> O["Recheck nightcrew_busy (PR #15)"]
    O -- Busy --> P["Skip claim this tick"]
    O -- Clear --> Q["claim-record.py claim (write record + live_refusal + flip label)"]
```

### 4.2 Matching rule and composite requirements

`agent-pool/scripts/capabilities.py` implements the Bamboo capability check:

- For a single-ability job (`requires = ["resolve"]`), a provider `p` matches if `"resolve" in abilities(p)`. Thus for `requires = ["resolve"]`, `claude`, `cursor`, `grok`, and `codex` match; `agy` does not.
- For a multi-ability job (`requires = ["test-author", "resolve"]`), `capabilities.py` checks `set(requires) <= set(abilities(p))`. Because `agy` lacks `resolve`, `agy` cannot claim a combined `["test-author", "resolve"]` job in one attempt. However, if a workflow labels the PR `agent:test-author` first, `agy` can claim and complete the `test-author` job; once the tests are committed and reviewed, the follow-up `resolve` job requires only `["resolve"]` and is claimed by `claude`, `cursor`, `grok`, or `codex`.

### 4.3 Interaction with leases, `live_refusal`, `reattempt`, and fencing

1. **Pre-claim capability check**:
   - `job_providers()` in `agent-pool/bin/prod-common.sh` is replaced by `capable_providers "$DJ" "$DREQUIRES"`.
   - `capable_providers` filters `PROVIDERS` (already vetted by `select_providers()` for binary, model, and provider-level cooldown) through:
     - `capabilities.py match --provider "$p" --requires "$DREQUIRES"`
     - `cooldown.py active --provider "$p" --ability "$ab"` for each `ab` in `DREQUIRES`
     - Prompt template existence check (`prompt_for "$p" "$DJ"`) moved from startup `select_providers()` to `capable_providers()`, so a provider that does not support `resolve` (like `agy`) is never faulted for lacking a `resolve` prompt template.
     - Gate infrastructure check: if `DREQUIRES` contains `resolve` or `test-author` and `$AGENT_POOL_STATE/faults/gates.json` is active (per `docs/plans/controller-gates.md` Section 3), `capable_providers` returns empty so gate-dependent jobs are not claimed while `plan`, `review`, and `prototype` jobs continue running.
2. **Atomic claim under the job lock (`agent-pool/scripts/claim-record.py`)**:
   - `claim-record.py claim` acquires `poolstate.locked(path)` on `$AGENT_POOL_STATE/claims/<repo>__<pr>.json.lock`.
   - `live_refusal()` in `claim-record.py` re-reads `gitea-pr.py state` live under the lock and additionally verifies `--expect-ability-labels`: if a human added or removed an `agent:<ability>` label since the candidate listing was taken at the start of the tick, `live_refusal()` returns exit 6 (`the live PR state no longer allows the claim`) so the worker never runs with a stale `requires` set.
   - `claim-record.py claim` also validates that `--provider` satisfies `--requires` via `capabilities.py` before writing the claim file, closing any race or misconfiguration in caller scripts.
3. **In-job provider fallback (`reattempt`) and fencing**:
   - In `run_job()` in `agent-pool/bin/prod-common.sh`, the loop iterates only over `JOB_PROVIDERS` (the providers in `C_eligible` that satisfy `DREQUIRES`).
   - When the first provider hits a `limit`, `timeout`, or `setup` fault and `run_job()` falls back to the next provider `p` via `claim-record.py reattempt --attempt "$ATTEMPT" --provider "$p"`, `reattempt` checks:
     1. `$ATTEMPT` is still the current attempt on disk (exit 4 if superseded by `doctor.sh` or another tick).
     2. The new provider `p` satisfies the claim record's `requires` list.
   - `reattempt` atomically writes a new `attempt_id` and fresh `expected_deadline_at`, fencing off any late process or trap from the previous provider via `watch_start()`, `still_held()`, `claim-record.py guard`, and `claim-record.py release`.

---

## 5. Doctor handling of jobs no available provider can satisfy (`needs-human` vs wait for cooldown)

A pull-based worker pool where workers only claim what they can satisfy introduces a classic scheduling hazard: **starvation of jobs whose requirements no available worker can meet**. If `PROVIDER_ORDER=agy` and a PR needs `resolve`, every `agy` tick will skip the PR forever unless the pool distinguishes *permanent capability mismatch* from *temporary cooldown unavailability*.

Both `agent-pool/bin/prod-common.sh` (during normal ticks) and `agent-pool/bin/doctor.sh` (on its 5-minute non-LLM timer from `docs/plans/agent-pool-worker-pool.md`) evaluate unsatisfiable `agent:ready` jobs using a deterministic three-tier partition. **Decided 2026-10-20 (Section 9): `C_roster` is checked against the host-wide roster, not the current tick's own `PROVIDER_ORDER`** — otherwise an `agy`-only tick would wrongly conclude a `resolve` job is unsatisfiable by anyone, even though a separate `claude` timer runs on the same host. `C_configured`/`C_eligible` still narrow by what the CURRENT tick can actually run:

- **`C_roster`**: providers in `REPO_ROSTER` whose capability manifest (`capabilities.py`) satisfies `job.requires`. `REPO_ROSTER` is not a separately maintained list. It is computed exactly the way `agent-pool/scripts/doctor.py` already computes its per-repo check on master: start from the host-wide roster `AGENT_POOL_ROSTER`, which is `repos.toml`'s existing `[pool].providers` (`roster = self.cfg["providers"]` in `doctor.py`), and keep each provider `p` for which `repoconfig.abilities(cfg, repo, p)` includes the job's ability on *the job's own repo*. A grant on some other repo never counts, so a `resolve` job on a repo that grants nobody `resolve` still escalates (the case `agent-pool/tests/verify-doctor.sh` already covers).
- **`C_configured`**: providers in `C_roster`, filtered to this tick's own `PROVIDER_ORDER`, that pass binary, model, and prompt preflight without a `SETUP FAULT`.
- **`C_eligible`**: providers in `C_configured` that are not in an active provider-level cooldown, not in an active ability-level cooldown for any ability in `job.requires`, and not blocked by an active `faults/gates.json` infra fault.

### Decision table for an `agent:ready` job with `C_eligible == empty`

| Condition | Meaning | Action by `prod-common.sh` / `doctor.sh` | Gitea label transition | Cooldown / fault effect |
|---|---|---|---|---|
| `C_roster` is empty | **Unsatisfiable by roster.** No provider in the host-wide `AGENT_POOL_ROSTER` that the job's repo grants the job's ability advertises `job.requires` (e.g., job requires `resolve` when `AGENT_POOL_ROSTER=agy`, or requires an ability combination no single provider has). | Claim briefly as `controller`, post a diagnostic comment naming `job.requires` and the capabilities of the providers in `AGENT_POOL_ROSTER`, and release to `agent:needs-human`. | `agent:ready` -> `agent:needs-human` | None (not a provider fault). |
| `C_roster` non-empty, `C_configured` is empty | **Host setup fault on all capable providers.** A capable provider is in `PROVIDER_ORDER`, but its binary is missing, its model env var is unset, or `faults/<provider>.json` is active. | Do **not** blame the PR. Leave the PR in `agent:ready`, log `SETUP FAULT`, and exit 2 so systemd / operator monitoring alerts. | Stays `agent:ready` | `cooldown.py fault` recorded per broken provider; tick exits 2. |
| `C_configured` non-empty, `C_eligible` is empty due to `faults/gates.json` | **Gate sandbox infra broken.** Capable providers exist for `resolve`/`test-author`, but controller gate sandbox failed on an earlier tick (`docs/plans/controller-gates.md` Section 3). | Leave the PR in `agent:ready`; log that gate-dependent abilities are paused until `faults/gates.json` clears. `plan`/`review`/`prototype` jobs still run. | Stays `agent:ready` | `faults/gates.json` remains active; tick exits 2. |
| `C_configured` non-empty, `C_eligible` is empty due to active cooldowns | **Temporary cooldown.** At least one configured provider can satisfy `job.requires`, but all such providers are currently cooling down (provider-level or ability-level). | **Wait for cooldown.** Touch nothing on Gitea; log the earliest `until` timestamp across `C_configured` (`waiting for cooldown; earliest eligible provider <p> in <Nm>`). | Stays `agent:ready` | Existing cooldowns tick down naturally. |

### How `doctor.sh` handles stale claims alongside capabilities

When `agent-pool/bin/doctor.sh` runs its 5-minute tick (`docs/plans/agent-pool-worker-pool.md`):

1. **Step 1 (Reconcile claimed jobs)**: For every open PR carrying `agent:claimed` or a claim file under `$AGENT_POOL_STATE/claims/`, `doctor.sh` runs `claim-record.py reconcile`. If a claim is `stale` (`now > expected_deadline_at` and no `.published` mark exists):
   - It records a cooldown for the timed-out claim's `(provider, job)` pair via `cooldown.py record --provider <prov> --ability <job>`.
   - It writes the durable reassignment notice to `$AGENT_POOL_STATE/mailboxes/<worker_id>/<message_id>.json` via `mailbox.py` and stops any active `prod-<provider>.service` unit.
   - It calls `claim-record.py requeue` to flip `agent:claimed` -> `agent:ready` and delete the claim file.
2. **Step 2 (Sweep `agent:ready` queue for unsatisfiable requirements)**:
   - For each open `agent:ready` PR not held by a human or NightCrew, `doctor.sh` derives `requires` and computes that PR's `REPO_ROSTER` (Section 5, `C_roster`) and runs `capabilities.py check-queue --order "$REPO_ROSTER" --roster "$REPO_ROSTER" --requires "$DREQUIRES"` (the doctor is host-wide, so its own order is the roster, narrowed per repo as `doctor.py` does today).
   - If `C_roster` is empty, `doctor.sh` (when `DOCTOR_DRY_RUN=0` and the repo is in the doctor's allowlist) transitions the PR from `agent:ready` to `agent:needs-human` with the explanation:
     `Automated pool stopped on this PR: job requires ability [<requires>], which no provider in the host-wide roster AGENT_POOL_ROSTER (<roster>) that this repo grants <ability> advertises.`
   - If `C_roster` is non-empty and `C_eligible` is empty because of cooldowns, `doctor.sh` logs `WAIT_COOLDOWN` with the remaining seconds until the next capable provider wakes up, and leaves `agent:ready` untouched.

---

## 6. Ability-level vs provider-level cooldowns

Today `agent-pool/scripts/cooldown.py` stores one file per provider at `$AGENT_POOL_STATE/cooldowns/<provider>.json` with a single `until` and `strikes` counter. Every cooldown blocks the provider across all job types. With five abilities of very different weight and failure modes, `cooldown.py` is extended to track **both** provider-level and ability-level cooldowns in the same atomic document.

### 6.1 When a cooldown is provider-level vs ability-level

| Failure source | Scope | Strike behavior | Why |
|---|---|---|---|
| Account credit wall (`Credit balance is too low`, `insufficient credits`, `purchase more credits` in `classify.py`) | **Provider-level** | Exponential backoff strike (`base * 2^(strikes-1)`, 1h to 24h cap) | Account has no funds; every ability (`plan`, `review`, `resolve`) on this provider will fail the same way. |
| Account-wide HTTP 429 / quota exhausted (`ANY_LIMIT` / `PRODUCT_LIMIT` in `classify.py`) | **Provider-level** (default) or **Ability-level** (when `AGENT_POOL_MODEL_<PROVIDER>_<ABILITY>` differs from the provider default) | Exponential backoff strike | If all abilities share one model and quota pool, the whole provider is rate-limited. If `resolve` uses a dedicated model tier with a separate quota from `review`, only abilities sharing that model cool down. |
| Fast-fail with no marker (`elapsed < AGENT_POOL_FAST_FAIL_SECS` and `fail-nomarker` in `prod-common.sh` line 676) | **Provider-level** | Exponential backoff strike | Matches the 32-second credit-wall / silent account rejection signature. |
| Worker timeout (`rc` 124/137 in `classify.py` or `WORKER_TIMEOUT` reached in `prod-common.sh` line 738) | **Ability-level** (`--ability <job>`) | Fixed pause (`AGENT_POOL_TIMEOUT_COOLDOWN=900`, no strike) | A provider that timed out on a 20-minute `resolve` or `prototype` can still complete a 2-minute `review` or `plan` while paused for `resolve`. |
| Stale claim reaped by `reconcile_pr()` or `doctor.sh` (`now > expected_deadline_at` with no `.published` mark) | **Ability-level** (`--ability <job>`) on first occurrence; escalates to **Provider-level** if 2 consecutive abilities go stale | Strike on the ability; provider strike if repeated across abilities | A silent hang on a heavy `resolve` pauses `resolve` first; if the provider also hangs on `review`, the provider daemon/CLI itself is wedged. |
| Repeated ability output-contract failure (e.g. `agy` in `prototype` or `test-author` failing patch extraction twice in a row) | **Ability-level** (`--ability <job>`) | Fixed pause (`AGENT_POOL_TIMEOUT_COOLDOWN`) | Stops a provider from burning ticks on an ability whose structured output format it is struggling with, while keeping its `review` and `plan` abilities active. |
| Setup fault (`classify.py` returns `setup`, tool denial, missing binary/model) | **Fault record** (`faults/<provider>.json` or `faults/<provider>__<ability>.json`) | No cooldown; logs `SETUP FAULT` and exits 2 | Per `cooldown.py` lines 9-12, setup faults must be fixed by an operator, except that an ability-specific setup fault (such as a missing `prompts/prototype.<provider>.txt`) only blocks that ability while other abilities remain runnable. |

### 6.2 Schema and CLI changes in `agent-pool/scripts/cooldown.py`

`$AGENT_POOL_STATE/cooldowns/<provider>.json` keeps its top-level provider fields (backward-compatible with existing tests in `agent-pool/tests/verify-lease.sh`) and adds an `"abilities"` map:

```json
{
  "provider": "claude",
  "strikes": 0,
  "since": 0,
  "until": 0,
  "seconds": 0,
  "reason": "",
  "abilities": {
    "resolve": {
      "strikes": 1,
      "since": 1792500000,
      "until": 1792500900,
      "seconds": 900,
      "reason": "claude hit the worker timeout (exit 124) after 1800s"
    }
  }
}
```

Subcommand behavior in `agent-pool/scripts/cooldown.py`:

- `cooldown.py record --provider P --reason R [--seconds S] [--ability A]`:
  - Without `--ability`: updates top-level `strikes` and `until` (provider-level cooldown).
  - With `--ability A`: updates `doc["abilities"][A]` using the same strike and lapse formula (`now - until > cap()` resets strikes to 0; `--seconds S` sets a fixed pause with no strike).
- `cooldown.py active --provider P [--ability A]`:
  - Computes `rem = remaining_provider(doc, now)`.
  - If `--ability A` is passed, `rem = max(rem, remaining_ability(doc, A, now))`.
  - Prints remaining seconds and exits 0 if `rem > 0`, else exits 1.
- `cooldown.py eligible --order a,b,c [--ability A[,B...]]`:
  - Returns providers in `--order` where top-level `remaining <= 0` AND, for every ability in `--ability`, `remaining_ability <= 0`.
- `cooldown.py clear --provider P [--ability A]`:
  - A verified completion on ability `A` clears `doc["abilities"][A]` strikes **and** clears top-level provider strikes (since any verified completion proves the provider's credentials and billing are working).

---

## 7. Publishing ability outputs

The commit/signing mechanism each of these flows uses (`controller_commit()`, signed `commit-tree`,
`Agent-Pool-*` trailers, marker `head=pending` stamping) is specified in its own plan,
`docs/plans/controller-commits-everything.md` — split out from here on 2026-10-20 because it is
an orthogonal worker-permission/security change, not a claim-routing one. What follows is what
each ability publishes and when; it assumes that mechanism exists for `prototype` and
`test-author` (which have no prior behavior to fall back to), and that `resolve` migrates onto
it from today's worker-commits-locally mechanism once that plan lands.

### 7.1 Publication flow per ability

#### A. Publishing `plan` outputs
1. **Worktree check**: `publish()` checks that `$JOB_WT` has no tracked edits (`gate_git --work-tree="$JOB_WT" diff --quiet "$sha"`). Any stray edits are discarded and not committed.
2. **Report validation**: `report.py plan --file "$report" --sha "$sha"` checks that the report is non-empty, passes `leaks_secret()` and host-path sanitization (`report.py sanitize`), and ends with:
   `<!-- pulse-plan:v1 head=<40-hex-sha> -->`
3. **Publication**: `comment_file "$report"` posts the plan comment to the PR/issue through `claim-record.py guard --attempt "$ATTEMPT"`.
4. **Release**: `release_to "$DONE"` strips `agent:claimed` (and `agent:plan` if present) and applies `agent:done`. No git commit or push occurs.

#### B. Publishing `prototype` outputs (throwaway worktree, never pushed unless promoted)
1. **Patch extraction (for `agy` in `--mode plan`) or worktree inspection (for edit-capable providers)**:
   - If the provider is `agy`, `report.py extract-patch --file "$result"` extracts the unified diff and applies it to `$JOB_WT` with `gate_git apply`.
   - `controller_commit()` stages the worktree changes into a private index, scans for secrets and protected tool-config paths, and creates a signed commit `proto_sha` with trailers (`Agent-Pool-Ability: prototype`, `Agent-Pool-Provider: <provider>`, etc.).
2. **Local controller ref, never pushed**:
   - The controller stores `proto_sha` under a local ref in `$MAIN`:
     `refs/agent-pool/prototypes/$JOB_PR/$ATTEMPT`
   - It **never** pushes `proto_sha` to `origin`. The throwaway worktree `$JOB_WT` is deleted in `end_job()`.
   - Optional informational gates: if `.agent-pool/gates.toml` exists, the controller can run `gates.py run` on `proto_sha` and include the gate table in the comment, but a red gate does **not** suppress posting the prototype comment.
3. **Comment content**:
   - The controller appends a `### Prototype artifact (not pushed)` section to the worker's report containing:
     - `git diff --stat "$sha" "$proto_sha"`
     - A collapsible `<details>` block with the sanitized unified diff (`git diff "$sha" "$proto_sha"` passed through `report.py sanitize`, capped at 64 KiB) so a human can inspect or `git apply` it directly from Gitea.
     - Instructions to promote: add label `agent:promote` + `agent:ready` to fast-forward push this prototype to the PR branch.
     - The marker: `<!-- pulse-prototype:v1 base=<sha> commit=<proto_sha> attempt=<attempt_id> files=<n> -->`
4. **Promotion flow (`agent:promote`)**:
   - When a human labels the PR `agent:promote` and `agent:ready`, `derive_job()` detects `agent:promote`, resolves `proto_sha` from the latest `pulse-prototype:v1` marker (`refs/agent-pool/prototypes/$JOB_PR/$attempt`), verifies `sha` is an ancestor of `proto_sha` and matches the live PR head, runs mandatory controller gates (`gates.py run`) on `proto_sha` if not already passed, pushes `proto_sha:refs/heads/$headref` through `claim-record.py guard`, posts a promotion confirmation comment, and releases to `agent:done` (stripping `agent:promote`).

#### C. Publishing `test-author` outputs (worker writes tests; controller runs them, commits, and pushes)
1. **Path scope verification**:
   - `controller_commit()` lists all changed files between `$sha` and `$JOB_WT` (`diff --name-only -z`).
   - If no files changed, `PUB="fail:test-author worker wrote no test changes"`.
   - Every changed file is checked against `gates.py test-paths --manifest "$MANIFEST"` (which matches `test_paths` globs from `.agent-pool/gates.toml` and rejects anything in `protect`, `.agent-pool/**`, lockfiles, or production source paths). Any violation aborts before gates run with `PUB="fail:test-author touched non-test paths (<paths>)"` -> `agent:needs-human`.
2. **Controller gate execution**:
   - The controller materializes the tree into `$GATE_DIR` (`docs/plans/controller-gates.md` Section 2.1) and runs `gates.py run` inside the network-isolated bubblewrap sandbox.
   - By default, all selected gates must exit 0 (`result=pass`). If a gate fails, nothing is pushed and the PR transitions to `agent:needs-human` with the sanitized gate log tail (`docs/plans/controller-gates.md` Section 3).
3. **Signed commit and guarded push**:
   - On gate pass, `controller_commit()` writes the signed commit `newhead` carrying `Agent-Pool-Ability: test-author` and provider/worker/attempt trailers, and writes the gate receipt to `$AGENT_POOL_STATE/gates/by-head/<slug>__<pr>__<newhead>.json`.
   - `report.py stamp-head` stamps `head=$newhead` into `<!-- pulse-test-author:v1 head=<newhead> base=<sha> tests_changed=<n> -->`.
   - The controller verifies `ls-remote origin refs/heads/$headref == $sha`, pushes `$newhead:refs/heads/$headref` via `guarded "push"`, and posts the report + controller gate section via `comment_file`.
4. **Handoff**:
   - If the PR carried only `agent:test-author`, `release_to "$DONE"` transitions to `agent:done` (stripping `agent:test-author`).
   - If the PR also carried `agent:resolve` (staged test-then-resolve workflow), the controller strips `agent:test-author` and releases back to `agent:ready` so the next tick claims the `resolve` phase on top of the newly pushed test commit.

---

## 8. Migration order after the controller-gates follow-up

Every step keeps all existing offline suites green (`agent-pool/tests/verify-lease.sh`, `agent-pool/tests/verify-providers.sh`, `agent-pool/tests/verify-nightcrew-issue-hold.sh`, `skills/pr-loops-common/tests/verify-merge.sh`, `skills/pr-loops-common/tests/verify-resolve.sh`, `skills/pr-loops-common/tests/verify-trigger.sh`, and `tests/verify-install.sh`).

### Step 0: Land prerequisite plans first
1. Land the `controller-gates` PR (`docs/plans/controller-gates.md` Steps 1-10): `agent-pool/scripts/gates.py`, `.agent-pool/gates.toml`, `gate_git`, bubblewrap gate runner, shrunk `agent-pool/scripts/policy.py`, `workerbin/git` PATH shim, `agy` removed from `resolve`, and `AGY_AUTO_APPROVE` retired.
2. Update `scripts/tools/night_shift.sh` (merged by PR #19) to drop the temporary `python3 -m unittest`, `python3 -m behave`, and `bash <dir>/verify-*.sh` allowances from Cursor's `.cursor/cli.json` and run `agent-pool/scripts/gates.py run` from the launcher after `cursor-agent` exits (closing PR #19's documented residual risk). Gitea issue #29 ("Cursor's commit trailer defeats the `git commit -m` allow rule, and cleanup force-removes the staged work") is a related, separate defect in the same launcher — its fix (rejecting `cursor-agent`'s `--trailer`-rewritten commits, or not force-removing a worktree with unstaged work on no-commit exit) is independent of this plan and should not block it, but touches the same file.
3. Land `docs/plans/controller-commits-everything.md` (its own migration, Section 5 there) before Step 4 below, since `prototype` and `test-author` have no fallback mechanism without it.

### Step 1: Capability manifest, requirement parser, and the host-wide roster
- **Files**: new `agent-pool/scripts/capabilities.py`; `agent-pool/scripts/repoconfig.py` gains a per-repo roster helper; `skills/pr-loops-common/gitea-labels.py`, `skills/pr-loops-common/pr-merge.sh`, `skills/pr-loops-common/marker.py`.
- Implement `agent-pool/scripts/capabilities.py` as a pure matcher with no knowledge of `repos.toml` (that stays `repoconfig.py`'s job — see "Relationship to `repos.toml`" in Section 2):
  - `ceiling --provider P` (and in-process `capabilities.ceiling(provider)`): prints the static hard ceiling for `P` (`agy` minus `resolve`), with no env narrowing. This is the only entry point `repoconfig.py` uses.
  - `abilities --provider P`: prints the effective abilities for `P` (baseline manifest intersected with `AGENT_POOL_CEILING_<P>`, never widening past the baseline ceiling).
  - `match --order CSV --requires CSV`: prints providers in `order` whose abilities are a superset of `requires`.
  - `parse-requires --labels JSON [--body FILE] --default-job J`: outputs the canonical `requires` CSV.
  - `check-queue --order CSV --requires CSV --roster CSV`: the `C_roster`/`C_configured`/`C_eligible` partition (Section 5). It takes the job's **repo-narrowed host roster** (`REPO_ROSTER`) as `--roster`, separately from the calling tick's own narrower `--order`, so an `agy`-only tick never wrongly concludes a `resolve` job is unsatisfiable just because `agy` itself can't do it. The caller (`prod-common.sh` or `doctor.sh`), not `capabilities.py`, computes `--roster`'s value per job as `REPO_ROSTER` by calling a new `repoconfig.py` helper (for example `roster --repo R --ability A`) that returns the providers in `[pool].providers` (`AGENT_POOL_ROSTER`) whose `repoconfig.abilities(cfg, R, p)` includes `A`, the same intersection `doctor.py` performs today, so `capabilities.py` stays free of `repos.toml`. This is resolved here, in Step 1, specifically because Step 3's `doctor.sh` escalation logic depends on getting it right from the start rather than being rebuilt once decided.
- Retire `repoconfig.py`'s local `CEILING` dict: replace its two use sites (`abilities()`'s `granted &= CEILING[provider]`, and the config-load warning when a provider table over-grants an ability) with a call to `capabilities.ceiling(provider)` (the static hard ceiling, with no `AGENT_POOL_CEILING_<PROVIDER>` narrowing), so the hard ceiling has exactly one definition. `AGENT_POOL_CEILING_<PROVIDER>` narrowing applies only on the `abilities`/`match`/`check-queue` path. `repoconfig.py`'s own tests (`agent-pool/tests/verify-doctor.sh`'s config-validation cases) must stay green unchanged, since the ceiling values themselves do not move, only their owner.
- Add `agent:plan`, `agent:review`, `agent:prototype`, `agent:test-author`, `agent:resolve`, and `agent:promote` to `LABELS` in `skills/pr-loops-common/gitea-labels.py` and update the blocking/cleanup label sets in `skills/pr-loops-common/pr-merge.sh`.
- Add `pulse-plan:v1`, `pulse-prototype:v1`, and `pulse-test-author:v1` marker parsers in `skills/pr-loops-common/marker.py` and `agent-pool/scripts/report.py`.
- Add unit tests in `agent-pool/tests/verify-lease.sh` and `skills/pr-loops-common/tests/verify-merge.sh`, including: an `agy`-only `PROVIDER_ORDER` with a host-wide roster that also includes `claude`, on a repo that grants `claude` `resolve`, does NOT escalate a `resolve` job to `agent:needs-human`; and a `resolve` job on repo A that grants nobody `resolve` DOES escalate even when repo B grants `claude` `resolve`.

### Step 2: Ability-level cooldowns in `agent-pool/scripts/cooldown.py`
- **Files**: `agent-pool/scripts/cooldown.py`, `agent-pool/tests/verify-lease.sh`.
- Add `--ability` support to `record`, `clear`, `active`, `eligible`, `fault`, and `show` in `agent-pool/scripts/cooldown.py`.
- Assert in `agent-pool/tests/verify-lease.sh` that:
  - An ability-level cooldown on `(claude, resolve)` blocks `eligible --order claude --ability resolve` while `eligible --order claude --ability review` still returns `claude`.
  - A provider-level cooldown on `claude` blocks all abilities.
  - `clear --provider claude --ability resolve` clears both the `resolve` ability cooldown and any top-level provider strikes.

### Step 3: Claim filtering by ability and unsatisfiable-job handling in `prod-common.sh` and `doctor.sh`
- **Files**: `agent-pool/scripts/claim-record.py`, `agent-pool/bin/prod-common.sh`, existing `agent-pool/bin/doctor.sh` (PR #21, extended here with capability-awareness — not new), `agent-pool/tests/verify-providers.sh`, new `agent-pool/tests/inject-staleness.sh`.
- Add `--requires` and `--expect-ability-labels` to `agent-pool/scripts/claim-record.py`.
- Replace `job_providers()` in `agent-pool/bin/prod-common.sh` with `capable_providers()`, implementing the `C_roster` / `C_configured` / `C_eligible` partition:
  - `C_roster` empty -> transition `agent:ready` to `agent:needs-human` with comment.
  - `C_configured` empty -> `SETUP FAULT`, keep `agent:ready`, exit 2.
  - `C_eligible` empty -> wait for cooldown, keep `agent:ready`, exit 0.
- Wire the same check into `agent-pool/bin/doctor.sh` alongside stale-claim reconciliation and mailbox enqueueing.
- Add end-to-end cases in `agent-pool/tests/verify-providers.sh`:
  - `PROVIDER_ORDER=agy` with `AGENT_POOL_ROSTER=agy` on a PR requiring `resolve` transitions immediately to `agent:needs-human` (the converse, an `agy`-only tick whose roster also includes `claude` with `resolve` granted on that repo, stays `agent:ready`; see the Step 1 test). A `resolve` PR on a repo that grants nobody `resolve` transitions to `agent:needs-human` even when another repo grants `claude` `resolve`, keeping `agent-pool/tests/verify-doctor.sh`'s per-repo case green.
  - `PROVIDER_ORDER=claude` where `claude` is on a `resolve` ability cooldown leaves a `resolve` PR in `agent:ready` (waiting for cooldown) while still claiming and completing a `review` PR in the same tick.

### Step 4: `plan`, `prototype`, and `test-author` execution, prompts, and publication
- **Prerequisite**: `docs/plans/controller-commits-everything.md` must be merged before this step — `prototype` and `test-author` have no mechanism to publish without `controller_commit()`.
- **Files**: `agent-pool/bin/prod-common.sh`, `agent-pool/scripts/policy.py`, `agent-pool/scripts/report.py`, `agent-pool/scripts/gates.py`, `skills/pr-loops-common/prompts/`.
- Add prompt templates `plan.generic.txt`, `prototype.generic.txt`, `prototype.agy.txt`, `test-author.generic.txt`, and `test-author.agy.txt` under `skills/pr-loops-common/prompts/`.
- Add `test_paths` validation to `agent-pool/scripts/gates.py` and `agent-pool/scripts/policy.py`.
- Add `report.py extract-patch` so `agy` can produce `prototype` and `test-author` changes in `--mode plan` without `--dangerously-skip-permissions`.
- Add `publish()` branches in `agent-pool/bin/prod-common.sh` for `plan`, `prototype` (saving to `refs/agent-pool/prototypes/<pr>/<attempt>` and never pushing), `agent:promote` (gating and pushing a promoted prototype), and `test-author` (enforcing test-only diff + controller gates + signed commit + guarded push).
- Add offline end-to-end tests in `agent-pool/tests/verify-providers.sh` covering all five abilities across all five providers (`claude`, `codex`, `cursor`, `grok`, `agy`).

---

## 9. Decisions (settled 2026-10-20)

All nine open questions from the first draft were settled in one review/grilling session with
Craig. Recorded here with rationale so the "why" survives past the conversation that produced
it.

1. **`agy`'s write mechanism for `prototype`/`test-author`: `--mode plan` + controller-side
   patch extraction — confirmed by direct test, not assumed.** The candidate middle ground
   (`--mode accept-edits --sandbox`) was empirically tested in a disposable directory on
   2026-10-20 and rejected: it ran an arbitrary shell command (`touch PWNED.txt` succeeded)
   despite `--sandbox`'s "terminal restrictions" claim. The plan's original design (Section 2,
   "How `agy` executes `prototype` and `test-author`") stands, for a proven reason.
2. **Relationship to "Conduits" (issue #6): a stepping stone, not a replacement — see Section 10.**
3. **Section 7 split into its own plan**, `docs/plans/controller-commits-everything.md` — done as
   part of this update. Ability-routing (this plan) and commit-authority (that plan) are
   orthogonal; bundling them grew the review surface and rollback blast radius for no benefit,
   on top of already depending on two other unmerged plans (`controller-gates.md`, PR #19).
4. **Host-wide roster, resolved before Step 3 builds on it** — see Section 5 and Step 1. Without
   it, a single-provider tick (e.g. `PROVIDER_ORDER=agy`) would wrongly conclude a job no other
   provider on the host can do, even when a separate timer for that provider exists right next
   to it.
5. **`test-author` gate mode: green by default, red opt-in.** `<!-- agent-pool-job:
   requires=test-author test-mode=red -->` opts into requiring the new test to fail cleanly
   before handoff to `resolve`. A silently-failing default gate would be a confusing, risky
   standard behavior.
6. **Composite `test-author`+`resolve`: two-stage by default.** This is what lets `agy` take
   `test-author` while staying excluded from `resolve`, and lets `protect` lock the just-written
   test files during the resolve stage so the resolver can't weaken its own test.
7. **Commit signing: SSH key, controller-only, required — see
   `docs/plans/controller-commits-everything.md` Section 4.**
8. **Commit granularity: one signed commit per run — see
   `docs/plans/controller-commits-everything.md` Section 4.**
9. **Prototype retention: TTL-based GC (14 days, as originally suggested), plus durability is a
   real decision, not an afterthought of garbage collection.** Chosen: lean on the controller
   host's existing backup routine rather than building new push-to-a-durable-branch
   infrastructure. If the controller host's backup coverage changes later, revisit whether
   unpromoted prototype refs need their own explicit backup path.
10. **Relationship to `repos.toml`'s existing per-repo `AGENT_POOL_ABILITIES` (PR #21, merged
    while this plan was open): extend, not replace.** `repos.toml` stays the per-repo
    authorization gate, unchanged; `capabilities.py` adds a per-provider, host-wide safety
    ceiling and per-job `requires` routing on top of it (Section 2, "Relationship to
    `repos.toml`"). The plan's own operator-narrowing var is renamed
    `AGENT_POOL_CEILING_<PROVIDER>` (was `AGENT_POOL_ABILITIES_<PROVIDER>`) to stop it colliding
    in name, though not in meaning, with `repos.toml`'s per-repo `AGENT_POOL_ABILITIES`. The
    host-wide `AGENT_POOL_ROSTER` (Section 5, Step 1) is likewise not a second config an
    operator maintains by hand: it is `repos.toml`'s existing `[pool].providers`, which
    `doctor.py` already uses as its roster. The `C_roster` check then narrows it per job to
    the providers the job's own repo grants the job's ability (`REPO_ROSTER`), exactly as
    `doctor.py` does today, before applying the ceiling and `requires`. `agent-pool/bin/doctor.sh` itself is
    existing (PR #21), extended here with capability-awareness, not built fresh. The
    per-provider ceiling itself (`agy` minus `resolve`) already exists too, as `repoconfig.CEILING`
    — a second, static copy of the same fact. Decided: `capabilities.py` becomes its one owner;
    `repoconfig.py` is changed to call it instead of keeping its own table (Section 2, Step 1),
    so the ceiling has exactly one definition and `AGENT_POOL_CEILING_<PROVIDER>` is the only
    way to narrow it further, never a second place to edit it.

## 10. Relationship to "Conduits" (issue #6)

GitHub issue #6 (`PR-Review-Resolver-Loop-Merge-Gitea-Github#6`) originally envisioned named,
database-configured agent personas (e.g. two differently-configured Claude-backed identities) —
richer than anything in this plan. That issue is now **closed**: Gitea issue #12 on this repo
turned out to already carry a more advanced, authorized, substantially-executed implementation
of the same idea (SQLite config-only registry, `agent-pool/` as the implementation home,
Charlie/Chase as canonical BDD examples), so #6 was closed in favor of it rather than left to
diverge as a second source of truth. Decided: **this plan is a stepping stone, not a
replacement, for whatever Conduits work lands under #12.** `capabilities.py`'s static
per-provider manifest stays the hard ceiling (Section 2: "can never widen a provider beyond its
hard ceiling"). If Conduits is built, named personas narrow within that ceiling, the same
pattern this plan already uses for `AGENT_POOL_CEILING_<PROVIDER>` — rather than this plan being
redesigned around a database that does not exist yet.

Refined during the same session: a **conduit is a template** — one per provider, each living in
its own repo (one repo per provider: Claude, Codex, Grok, Agy, Cursor). The tunable settings
(personality, model, and other per-conduit knobs) are externalized to a database or TOML file,
editable through a UI, rather than hardcoded into the template repo itself. This refinement is
not designed further here; it belongs in issue #6, not in this plan.
