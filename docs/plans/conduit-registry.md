# Conduit registry: Slice 1 contracts, schema and matching

Status: Slice 1 of the Conduit plan (Gitea issue #12). A local library, an offline CLI, a
versioned SQLite schema, an example fixture and tests. Nothing here is wired into
`prod-common.sh`, a dispatcher, `policy.py` or any provider CLI, and nothing invokes an agent.

## Decisions this slice implements

- **Storage (2026-10-19).** A core-owned, configuration-only SQLite registry using the Python
  standard library's `sqlite3`. It holds providers, model policies, conduits, capabilities,
  skills, permissions and grants. Jobs, claims, leases, fences, worker registration, scheduling
  and attempt receipts stay outside it; the file-backed claim records (`claim-record.py`, UUID
  `attempt_id` fencing) remain authoritative. TheNightCrew's database and the Factory
  `moonlighter` migrations remain off-limits.
- **Ownership.** This repository (`agent-pool/`) is the implementation home. TheGiteaCodeFactory
  is the later distribution and convergence destination.

## Files

| Path | What it is |
| --- | --- |
| `agent-pool/scripts/conduit_registry.py` | The library: schema v1, `migrate`, `apply_configuration`, `seed_examples`, `load_conduit`, `match_conduit`, `admin_transaction`, `credential_rules`. Stdlib only. |
| `agent-pool/scripts/conduit-registry.py` | Thin CLI over the library. |
| `agent-pool/config/conduits.example.json` | The Charlie and Chase example fixture. |
| `agent-pool/config/skills/tdd.md` | The TDD procedure fixture; its integrity is the SHA-256 of its bytes. |
| `agent-pool/tests/verify-conduits.sh` | The gate: unit tests, then the Gherkin feature, under one interpreter. |
| `agent-pool/tests/conduits/test_*.py` | Pure matching, SQLite integration, CLI, examples, scanner, result checker and gate-wrapper tests. |
| `agent-pool/tests/features/conduits.feature` | Executable acceptance scenarios, with `steps/` and `environment.py`. |
| `agent-pool/tests/check-behave-result.py` | Accepts a Behave JSON result only for a non-empty, all-passed run. |
| `agent-pool/tests/scan-conduit-secrets.py` | Diff-scoped filename and content scanner. |
| `agent-pool/tests/requirements-conduits.lock` | Hashed development lockfile for Behave 1.3.3 and its transitives. |

## Storage contract (schema version 1)

- Every operation takes an explicit absolute path to an existing directory, outside this
  checkout. Importing the module creates nothing; only `migrate` creates a file.
- Every connection enables `PRAGMA foreign_keys` and a 5 second busy timeout
  (`BUSY_TIMEOUT_SECONDS`). Writes run in one `BEGIN IMMEDIATE` transaction and roll back on any
  exception, interrupts included. A lock held past the timeout raises `RegistryBusyError`.
- `PRAGMA user_version` holds the schema version. `migrate` turns version 0 (an empty file) into
  version 1 in one transaction, returns 1 unchanged, and refuses any other version, or an
  unversioned file that already holds tables, without changing a byte. There is no downgrade and
  no reset command.
- Reads (`load_conduit`) open the file read-only (`mode=ro`) in one transaction and refuse a
  missing file (`missing_database`, never created), version 0 (`schema_missing`) and any version
  other than 1 (`unsupported_schema`).
- Tables: `providers`, `model_policies`, `model_policy_models`, `capabilities`, `permissions`,
  `skills`, `conduits`, `conduit_capabilities`, `conduit_permissions`, `conduit_skills`.
  Identifiers are lowercase (`[a-z0-9][a-z0-9._-]{0,63}`); names are nonempty; `enabled` is an
  integer constrained to 0 or 1. Every foreign key is `ON DELETE RESTRICT ON UPDATE RESTRICT`.
  `model_policies` is unique on `(id, provider_id)` and `conduits` references it by that pair, so
  a conduit's policy always belongs to the conduit's provider. `conduits.invocation_json` must be
  a nonempty JSON array whose first element equals `executable`. `skills` is keyed by
  `(id, version)` with a 64 lowercase hex `integrity_sha256`.
- No column holds a credential, a credential reference, an environment value or arbitrary
  metadata.

## Configuration documents

`apply_configuration(path, document)` takes one self-contained JSON document:
`{"format": "conduit-registry/v1", "providers": [...], "model_policies": [...],
"capabilities": [...], "permissions": [...], "skills": [...], "conduits": [...]}`. Every row must
carry exactly its allowlisted keys (see `SECTION_KEYS`); references must resolve within the
document. Validation is complete before anything is written:

- Policy cardinality: `fixed` declares exactly one model, `allow_list` at least one, `auto` none.
  Model ids are distinct lowercase identifiers. A conduit whose policy belongs to another
  provider is rejected.
- Invocation is a nonempty argv list of strings with `argv[0]` equal to `executable`. It is
  declarative; no shell evaluates it and nothing runs it in this slice.
- Every string (keys included) is checked against `CREDENTIAL_RULES` (private-key headers, known
  provider token prefixes, literal credential assignments; the shapes `report.py scan` refuses).
  A match is rejected with the JSON path and rule name, never the value. This rejects obvious
  credentials; it does not claim arbitrary text can be perfectly classified.
- Rows that already exist identically are left alone, so repeating a document is a no-op. Any
  difference, including a conduit's grant set or a policy's declared models, raises
  `ConflictError` and nothing is written: operator edits are never overwritten.

`seed_examples(path)` applies `agent-pool/config/conduits.example.json`, replacing each skill's
`procedure` file name with the SHA-256 of that file's bytes.

`admin_transaction(path)` yields a connection inside a `BEGIN IMMEDIATE` transaction on an
existing version 1 registry for operator edits; constraint violations raise `ConstraintError`.

## Example conduits

| Conduit | Provider | Model policy | Capabilities | Permissions | Skills |
| --- | --- | --- | --- | --- | --- |
| Charlie | `claude` | `auto` | planning, reviewing | plan, review | none |
| Chase | `claude` | `fixed`: `sonnet` | coding | code, test | `tdd` 1.0.0 |

Both declare executable `claude` and invocation `["claude"]`. Neither holds a merge permission.
`sonnet` is a declared provider alias, not an observed model; translating a policy into CLI
flags belongs to a later slice.

## Matching

`match_conduit(snapshot, request)` is pure: no filesystem, process or network effects. A
`MatchRequest` carries required capability ids, required permission ids, required skills as
`(id, version, integrity_sha256)`, and the approval context (`actor_id`, `revision_sha`,
`authored_by`, `approves_revision`). The result is `MatchResult(eligible, reasons)`, with
`reasons` a sorted tuple of distinct codes:

| Code | When |
| --- | --- |
| `unknown_conduit` | No snapshot. Returned alone. |
| `invalid_request` | Empty capability or permission requirements, or a malformed field. Returned alone. |
| `disabled_configuration` | The conduit, its provider or its policy is disabled or the provider is absent; or a required capability, permission or skill is granted but disabled. |
| `invalid_model_policy` | The policy is absent, is not the conduit's, belongs to another provider, or fails cardinality (revalidated on every match, so a stored policy that lost its model fails closed). |
| `missing_capability` / `missing_permission` | A required id is not granted. |
| `missing_skill` | No grant with the exact id, version and integrity. |
| `approval_context_missing` | `approves_revision` without an actor, a revision or its authors. |
| `self_approval` | The approving actor is among the revision's authors (case-insensitive). |

The self-approval rule is about actors, not conduits: the same actor approving through a
different conduit is still denied, and a capability grant never overrides it. A disabled grant
that the request does not need does not deny.

## CLI

```
conduit-registry.py migrate       --database PATH
conduit-registry.py seed-examples --database PATH
conduit-registry.py apply         --database PATH --config FILE
conduit-registry.py show          --database PATH --conduit ID
conduit-registry.py match         --database PATH --conduit ID --request FILE
```

Every command prints one JSON document. Exit 0 is administrative success, a conduit shown or an
eligible match. Exit 3 is a denial, including an unknown conduit or an invalid request. Exit 2
is malformed input or a path, storage or schema failure, with `{"error": code, "message": ...}`
on stderr that never quotes an input value.

## Not implemented here (runtime obligations for later slices)

Schema and matching are a specification boundary, not a deployed authorization endpoint. Before
any dispatcher acts on a match, a later slice must:

- resolve the actor identity from a trusted caller, never from a conduit name;
- require both registry eligibility and the existing `policy.py` execution policy;
- verify a skill's content against its registered integrity before use;
- observe and record the model that actually ran (a configured `fixed`/`auto` policy is never
  evidence of it, and this slice records no actual-model receipt);
- audit which registry revision a decision read.

Modes, personalities, networking, scheduling, the AMPB control panel and production enablement
are out of scope.

## Gate

```
bash agent-pool/tests/verify-conduits.sh
```

The gate selects `${CONDUITS_PYTHON:-python3}`, logs its version and Behave's, and runs exactly:

```
PYTHONPATH=agent-pool/scripts python -m unittest discover -s agent-pool/tests/conduits -p 'test_*.py' -v
PYTHONPATH=agent-pool/scripts python -m behave agent-pool/tests/features/conduits.feature --format json --outfile RESULT
```

The `--format json --outfile` options exist so that `check-behave-result.py` can inspect the
structured result. A missing interpreter, a missing Behave, a nonzero exit, zero scenarios, or
any skipped, untested, undefined, pending, failed or errored scenario or step fails the gate.
Install Behave into a dedicated environment from the hashed lockfile (see its header), for
example `uv pip install --python <venv>/bin/python --require-hashes -r
agent-pool/tests/requirements-conduits.lock`, and point `CONDUITS_PYTHON` at that interpreter.

Known gap: `scripts/tools/night_shift_maintenance.sh quality` runs each suite under `env -i`
with only `HOME`, `PATH`, `TMPDIR` and `LANG`. That drops `CONDUITS_PYTHON`, so this gate fails
there unless the `python3` on `PATH` has Behave. That is the intended fail-closed behaviour; the
fix is for the maintenance script to pass `CONDUITS_PYTHON` through.

Diff-scoped secret scan, run on the commit range under review:

```
python3 agent-pool/tests/scan-conduit-secrets.py --base BASE_SHA --head HEAD_SHA
```

Exit 0 clean, 1 findings (`path<TAB>rule`, never the matched text), 2 scan failure. Deleted paths
are skipped, renames are scanned under their new name, binary blobs are scanned whole, and a
changed path that is not a readable blob fails the scan.

## Differences from the original plan

- The plan's Chase also had a "repository coding standards" skill and permissions for branches,
  commits and implementation PRs. The approved Slice 1 packet seeds only `tdd` 1.0.0 and the
  `code` and `test` permissions, so that is what the fixture holds.
- The plan expressed "cannot review his own authored implementation" per conduit. The approved
  contract makes it a rule about trusted actor identity, so two conduits never create
  independence for one actor.
- The original issue body allowed at most an opaque secret reference key. The approved schema
  has no credential column at all.
- Model policies are declarations only. No provider flags or modes are derived from them yet.
