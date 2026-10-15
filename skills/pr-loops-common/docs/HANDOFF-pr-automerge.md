# Handoff: PR auto-merge tick (separate from review/resolve)

**Date:** 2026-09-23 (America/Toronto)  
**From:** Feudal Frontiers dotcom (Grok Bot)  
**For:** Codex (via Cordelia)  
**Repo context:** Gitea `ElasticGun/TheNightCrew` is the first consumer; skills live on Craig’s machine under `~/.claude/skills/`, not inside TheNightCrew git tree.  
**Auth:** do **not** push / merge / open PRs unless Craig explicitly asks in this Codex session.

---

## Goal

Add a **third, mechanical** label-driven tick that merges open Gitea PRs after review/resolve succeed — without teaching review/resolve workers to merge.

> **STATUS: shipped.** This gap is closed — `/pr-merge-loop` implements the third tick described
> below, and the blanket merge denial in `ampb-pipeline-guardrails.mjs` was dropped once it proved
> out. Kept for the design rationale. The "must stay never merges" constraint on the review and
> resolve wrappers still holds: only the merge tick merges.

Historically `pr-loop.sh` stopped at `review:clean` or `review:resolved` and Craig merged by hand (#28, #29); this handoff was the agreed shape for automating it.

## Done already (context, do not redo)

- Review + resolve loops work via `pr-loop.sh review|resolve` + `gitea-pr.py` + markers.
- Merge is **intentionally absent** from `gitea-pr.py` (see header comment lines ~17–19).
- Workers DENY `tea pr merge`, approve, close, force-push, etc. (`pr-loop.sh` DENY list). Keep that.
- NightCrew PR #29 merged by Craig: Friday block cancels Saturday overnight carry.
- Sketch approved in chat 2026-09-23 ~21:20 ET; product open calls below have **recommended defaults** so implement can proceed.

## Source of truth (paths on cachyos / craigpar)

| Path | Role |
|------|------|
| `~/.claude/skills/pr-loops-common/pr-loop.sh` | review/resolve ticks; never merges |
| `~/.claude/skills/pr-loops-common/gitea-pr.py` | Gitea adapter; hybrid tea writes + API reads; **no merge subcommand yet** |
| `~/.claude/skills/pr-loops-common/gitea-labels.py` | rolls `review:*` labels; extend for new labels |
| `~/.claude/skills/pr-loops-common/marker.py` | `pulse-review:v1` / `pulse-resolve:v1` marker gate |
| `~/.claude/skills/pr-review-loop/`, `pr-resolve-loop/`, `pr-review-resolve-loop/` | skill wrappers; must stay “never merges” |
| `~/.local/state/gitea-pr-loops/` | locks + `pr-loop.log` |
| Env: `PR_LOOP_REPO`, `PR_LOOP_MAIN` | e.g. `ElasticGun/TheNightCrew`, `/home/craigpar/Code/TheNightCrew` |

Gitea forge (prefer Tailscale for phone): `http://ubuntu-2404.tail99f840.ts.net:3000`  
LAN: `http://192.168.2.48:3000`  
`tea` login: `gitea-local`; token: `GITEA_TOKEN` or `~/.config/pulse/gitea_token`.

## Design (locked)

### Why separate

Auto-merge is a **third tick** with its own claim label and gates. Do **not** bolt merge into review/resolve workers or into a quiet helper on `gitea-pr.py` that anything can call by accident — add an **explicit** `merge` subcommand.

### Trigger

Open, non-draft PRs that have **either**:

- `review:clean` (review found 0 findings), or  
- `review:resolved` (resolve FF-pushed + marker ok)

**Never** merge if any of: `review:needs-human`, `review:in-progress`, `review:resolving`, `review:findings`, `review:requested`.  
If `needs-human` is present **alongside** clean/resolved, **needs-human wins** (skip / fail closed).

### Phase 1 opt-in (required)

Also require label **`review:automerge`** so humans can leave clean/resolved PRs unmerged until they want the button. NightCrew-only / allowlist first.

### Flow (`pr-loop.sh merge` **or** sibling `pr-merge.sh` — prefer sibling if it keeps `pr-loop.sh` MODE case smaller)

1. List open PRs via existing adapter.
2. Filter: has (`review:clean` OR `review:resolved`) AND `review:automerge`; not needs-human; not draft; not bot (same skips as review).
3. Claim: remove clean/resolved (and keep or strip automerge — prefer strip automerge on claim) → add **`review:merging`**.
4. Gates (bash only — **no Claude worker** in phase 1):
   - Head SHA still matches last verified marker (`pulse-review:v1` for clean path, `pulse-resolve:v1` for resolved path) — same philosophy as today’s label moves.
   - Gitea API `mergeable == true`.
   - Base ref allowlist: `develop` for NightCrew (or repo default_branch if you generalize carefully).
   - **Defer CI:** NightCrew currently has **no** branch protection and **no** commit statuses on develop. Phase 1 = label + mergeable + marker only. Leave a clear TODO hook for required status contexts later.
5. Merge **only** via new entrypoint: `gitea-pr.py merge --repo O/R --pr N --style …` wrapping `tea pr merge`.
6. Success: strip `review:merging` (+ any leftover review labels) → add **`review:merged`**; comment with head SHA + style + utc time.
7. Fail: strip `review:merging` → `review:needs-human` + comment with reason (conflict, head moved, API error, not mergeable).

### New pieces

| Piece | Role |
|-------|------|
| `gitea-pr.py merge` | **only** merge entrypoint; explicit name; document in module docstring |
| `review:merging`, `review:merged`, `review:automerge` | claim / terminal / opt-in — extend `gitea-labels.py` |
| `pr-merge.sh` or `pr-loop.sh merge` | deterministic tick; cron after review/resolve |
| skill `/pr-merge-loop` | one-line invoke; docs say never called from review/resolve |

### Hard rules

- Do **not** teach resolve workers or `pr-review-resolver` to merge.
- Do **not** rely on Gitea “auto-merge when checks pass” as the only path until branch protection + CI exist.
- Do **not** widen DENY list gaps so workers can call `gitea-pr.py merge`.
- DRY_RUN=1 must list candidates and print would-merge without mutating.

## Product defaults (use unless Craig overrides in-session)

| Call | Default |
|------|---------|
| Merge style | **`merge`** (matches Gitea repo `default_merge_style` on TheNightCrew today) |
| Delete branch after merge | **no** (repo default) |
| Opt-in | **`review:automerge` required** (phase 1); later default-on for allowlisted repos |
| First repo | `ElasticGun/TheNightCrew` only until proven |

## How to verify

1. `gitea-labels.py --repo ElasticGun/TheNightCrew` dry-run shows new labels; `--apply` creates them.
2. `DRY_RUN=1 PR_LOOP_REPO=ElasticGun/TheNightCrew PR_LOOP_MAIN=/home/craigpar/Code/TheNightCrew ./pr-merge.sh` (or `pr-loop.sh merge`) lists only PRs with automerge+clean|resolved.
3. Offline unit/shell tests for: needs-human wins; missing automerge skips; head-moved fails to needs-human; mergeable false fails; marker mismatch fails.
4. Live smoke (only if Craig authorizes): open a tiny throwaway PR, label `review:clean` + `review:automerge`, run tick, confirm merged + `review:merged` + comment; confirm a second PR with only `review:resolved` (no automerge) is left alone.
5. Confirm `pr-loop.sh review` / `resolve` still refuse merge (DENY + prompts unchanged).

## Risks

- Merging without CI while NightCrew has no protection — mitigated by opt-in label.
- Race: human pushes after resolve marker → marker/head gate must refuse.
- Claiming (`review:merging`) then crash mid-merge → leave needs-human, never silent half-state.
- Accidental call from Claude worker — keep merge out of ALLOW; only the merge tick’s bash calls `gitea-pr.py merge`.
- Editing `pr-loop.sh` while a long tick runs — existing pin-to-temp pattern; new script should follow same if it can run long (merge tick should be short).

## Out of scope

- Feudal Frontiers monorepo stand-up.
- NightCrew `feature/parked-heartbeat` push.
- Wiring Gitea branch protection / Actions (phase 3 hook only).
- Changing AMPB/Pulse upstream GH `gh`-based loops beyond what’s needed for Gitea parity docs.

## Open for Craig (non-blocking if defaults accepted)

1. Squash vs merge commit forever?  
2. Delete branch after merge?  
3. When to drop opt-in and auto-merge all ElasticGun/* clean|resolved?

## Suggested Codex work order

1. Read `gitea-pr.py`, `pr-loop.sh` (label/claim/verify sections), `marker.py`, `gitea-labels.py`.  
2. Add labels to `gitea-labels.py`.  
3. Implement `gitea-pr.py merge` (tea wrap + API precheck mergeable/head).  
4. Implement merge tick script + `/pr-merge-loop` skill.  
5. Tests + DRY_RUN demo against TheNightCrew.  
6. **Stop before push**; report diff paths + verify commands; wait for Craig to say push / apply labels / cron.

## Related chat decisions

- 2026-09-23: Craig merged #29; wants automerge fixed eventually.  
- Same evening: asked for this sketch; then asked for this handoff sent to Codex.
