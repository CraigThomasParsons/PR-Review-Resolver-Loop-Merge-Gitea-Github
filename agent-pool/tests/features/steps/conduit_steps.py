"""Step bindings for conduits.feature, run against the real library and real SQLite files."""
import dataclasses
import sqlite3
import sys
import time
from pathlib import Path
from unittest import mock

from behave import given, then, use_step_matcher, when

_ROOT = Path(__file__).resolve().parents[4]
for _path in (_ROOT / "agent-pool" / "scripts", _ROOT / "agent-pool" / "tests" / "conduits"):
    if str(_path) not in sys.path:
        sys.path.insert(0, str(_path))

import conduit_registry as registry  # noqa: E402
from conduit_registry import MatchRequest, MatchResult, SkillRequirement, match_conduit  # noqa: E402
from conduit_test_support import (  # noqa: E402
    EXAMPLES, TDD_PROCEDURE, minimal_configuration, synthetic_secrets, tdd_integrity,
)

use_step_matcher("parse")

DISABLEABLE = {"conduits", "providers", "model_policies", "capabilities", "permissions", "skills"}


class SimulatedInterrupt(BaseException):
    """Stands in for a crash or signal between two inserts of one transaction."""


def split(text: str) -> tuple[str, ...]:
    return tuple(item for item in text.split(",") if item and item != "-")


def dump(path: Path) -> list[str]:
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        return [f"user_version={connection.execute('PRAGMA user_version').fetchone()[0]}",
                *connection.iterdump()]
    finally:
        connection.close()


def remember(context) -> None:
    context.baseline = dump(context.db)


def expect_error(context, operation) -> None:
    context.error = None
    try:
        operation()
    except registry.RegistryError as error:
        context.error = error
    assert context.error is not None, "the operation was expected to fail and did not"


def update_request(context, **changes: object) -> None:
    context.request = dataclasses.replace(context.request, **changes)


# --- registry setup ---------------------------------------------------------------------------

@given("an empty sandbox")
def step_empty_sandbox(context) -> None:
    assert list(context.sandbox.iterdir()) == []


@given("a migrated registry")
def step_migrated(context) -> None:
    assert registry.migrate(context.db) == 1
    remember(context)


@given("a migrated registry seeded with the example conduits")
def step_seeded(context) -> None:
    registry.migrate(context.db)
    registry.seed_examples(context.db)
    remember(context)


@given("a migrated registry with the test-only dual conduit")
def step_dual(context) -> None:
    registry.migrate(context.db)
    registry.apply_configuration(context.db, minimal_configuration())
    remember(context)


@given("a registry file reporting schema version {version:d}")
def step_newer_file(context, version: int) -> None:
    connection = sqlite3.connect(str(context.db), isolation_level=None)
    try:
        connection.execute("CREATE TABLE future_registry (x)")
        connection.execute(f"PRAGMA user_version = {version}")
    finally:
        connection.close()
    context.file_bytes = context.db.read_bytes()


@given('an operator disables {table} row "{row}"')
def step_disable(context, table: str, row: str) -> None:
    assert table in DISABLEABLE, table
    with registry.admin_transaction(context.db) as connection:
        assert connection.execute(f"UPDATE {table} SET enabled = 0 WHERE id = ?", (row,)).rowcount >= 1
    remember(context)


@given('an operator renames conduit "{conduit_id}" to "{name}"')
def step_rename(context, conduit_id: str, name: str) -> None:
    with registry.admin_transaction(context.db) as connection:
        connection.execute("UPDATE conduits SET name = ? WHERE id = ?", (name, conduit_id))
    remember(context)


@given('an operator deletes the models of policy "{policy_id}"')
def step_delete_models(context, policy_id: str) -> None:
    with registry.admin_transaction(context.db) as connection:
        connection.execute("DELETE FROM model_policy_models WHERE model_policy_id = ?", (policy_id,))
    remember(context)


@given("another connection holds the write lock")
def step_hold_lock(context) -> None:
    holder = sqlite3.connect(str(context.db), isolation_level=None)
    holder.execute("BEGIN IMMEDIATE")

    def release() -> None:
        holder.execute("ROLLBACK")
        holder.close()

    context.cleanups.append(release)


# --- requests ---------------------------------------------------------------------------------

@given('a request requiring capabilities "{capabilities}" and permissions "{permissions}"')
def step_request(context, capabilities: str, permissions: str) -> None:
    context.request = MatchRequest(required_capabilities=split(capabilities),
                                   required_permissions=split(permissions))


@given("a request with no required capabilities or permissions")
def step_empty_request(context) -> None:
    context.request = MatchRequest(required_capabilities=(), required_permissions=())


@given('the request requires skill "{skill_id}" version "{version}" with the fixture integrity')
def step_skill(context, skill_id: str, version: str) -> None:
    requirement = SkillRequirement(skill_id, version, tdd_integrity())
    update_request(context, required_skills=context.request.required_skills + (requirement,))


@given('the request requires skill "{skill_id}" version "{version}" with a different integrity')
def step_skill_other_integrity(context, skill_id: str, version: str) -> None:
    other = "0" * 64
    assert other != tdd_integrity()
    requirement = SkillRequirement(skill_id, version, other)
    update_request(context, required_skills=context.request.required_skills + (requirement,))


@given('the request approves revision "{revision}" as actor "{actor}" authored by "{authors}"')
def step_approves(context, revision: str, actor: str, authors: str) -> None:
    update_request(context, approves_revision=True, revision_sha=revision, actor_id=actor,
                   authored_by=split(authors))


@given('actor "{actor}" authored revision "{revision}" through conduit "{conduit_id}"')
def step_authored(context, actor: str, revision: str, conduit_id: str) -> None:
    assert registry.load_conduit(context.db, conduit_id) is not None
    context.authorship = {"actor": actor, "revision": revision, "conduit": conduit_id}


@given('the request approves that revision as actor "{actor}"')
def step_approves_that(context, actor: str) -> None:
    authorship = context.authorship
    update_request(context, approves_revision=True, revision_sha=authorship["revision"], actor_id=actor,
                   authored_by=(authorship["actor"],))


@given("the request approves a revision without actor context")
def step_approves_blind(context) -> None:
    update_request(context, approves_revision=True, actor_id=None, revision_sha=None, authored_by=())


# --- actions ----------------------------------------------------------------------------------

@when('conduit "{conduit_id}" is loaded and matched')
def step_match(context, conduit_id: str) -> None:
    context.snapshot = registry.load_conduit(context.db, conduit_id)
    context.result = match_conduit(context.snapshot, context.request)


@when('conduit "{conduit_id}" is loaded, its policy reassigned to provider "{provider_id}", and matched')
def step_match_mismatched(context, conduit_id: str, provider_id: str) -> None:
    snapshot = registry.load_conduit(context.db, conduit_id)
    policy = dataclasses.replace(snapshot.model_policy, provider_id=provider_id)
    context.snapshot = dataclasses.replace(snapshot, model_policy=policy)
    context.result = match_conduit(context.snapshot, context.request)


@when('conduit "{conduit_id}" is loaded and then matched with effects forbidden')
def step_match_pure(context, conduit_id: str) -> None:
    context.snapshot = registry.load_conduit(context.db, conduit_id)

    def forbidden(*args: object, **kwargs: object) -> None:
        raise AssertionError("match_conduit must not perform effects")

    with mock.patch("builtins.open", forbidden), mock.patch("os.open", forbidden), \
            mock.patch("subprocess.Popen", forbidden), mock.patch("os.fork", forbidden), \
            mock.patch("os.system", forbidden), mock.patch("socket.socket", forbidden):
        context.result = match_conduit(context.snapshot, context.request)


@when('conduit "{conduit_id}" is loaded expecting an error')
def step_load_error(context, conduit_id: str) -> None:
    expect_error(context, lambda: registry.load_conduit(context.db, conduit_id))


@when("the registry is migrated")
def step_migrate(context) -> None:
    context.version = registry.migrate(context.db)
    context.first_migration = context.db.read_bytes()


@when("the registry is migrated again")
def step_migrate_again(context) -> None:
    context.version = registry.migrate(context.db)


@when("the registry is migrated expecting an error")
def step_migrate_error(context) -> None:
    expect_error(context, lambda: registry.migrate(context.db))


@when("the examples are seeded again")
def step_seed_again(context) -> None:
    registry.seed_examples(context.db)


@when("the examples are seeded again expecting an error")
def step_seed_again_error(context) -> None:
    expect_error(context, lambda: registry.seed_examples(context.db))


@when("the examples are seeded with a {seconds:g} second busy timeout expecting an error")
def step_seed_busy(context, seconds: float) -> None:
    started = time.monotonic()
    with mock.patch.object(registry, "BUSY_TIMEOUT_SECONDS", seconds):
        expect_error(context, lambda: registry.seed_examples(context.db))
    context.elapsed = time.monotonic() - started


@when("seeding the examples is interrupted after {rows:d} rows")
def step_interrupted(context, rows: int) -> None:
    real = registry._insert_row
    calls = []

    def interrupted(*args: object) -> None:
        calls.append(args)
        if len(calls) > rows:
            raise SimulatedInterrupt()
        real(*args)

    with mock.patch.object(registry, "_insert_row", interrupted):
        try:
            registry.seed_examples(context.db)
        except SimulatedInterrupt:
            pass
        else:
            raise AssertionError("the seed was not interrupted")
    assert len(calls) == rows + 1


@when('an operator grants conduit "{conduit_id}" the unknown capability "{capability_id}"')
def step_dangling_grant(context, conduit_id: str, capability_id: str) -> None:
    def grant() -> None:
        with registry.admin_transaction(context.db) as connection:
            connection.execute("INSERT INTO conduit_capabilities VALUES (?, ?)", (conduit_id, capability_id))

    expect_error(context, grant)


@when('an operator deletes provider "{provider_id}"')
def step_delete_provider(context, provider_id: str) -> None:
    def delete() -> None:
        with registry.admin_transaction(context.db) as connection:
            connection.execute("DELETE FROM providers WHERE id = ?", (provider_id,))

    expect_error(context, delete)


@when('an operator inserts provider "{provider_id}" again')
def step_duplicate_provider(context, provider_id: str) -> None:
    def insert() -> None:
        with registry.admin_transaction(context.db) as connection:
            connection.execute("INSERT INTO providers VALUES (?, 'Duplicate', 1)", (provider_id,))

    expect_error(context, insert)


def apply(context, document: dict) -> None:
    context.error = None
    try:
        registry.apply_configuration(context.db, document)
    except registry.ConfigurationError as error:
        context.error = error


@when('a configuration with a "{kind}" policy declaring models "{models}" is applied')
def step_apply_policy(context, kind: str, models: str) -> None:
    document = minimal_configuration()
    document["model_policies"][0].update(kind=kind, models=list(split(models)))
    apply(context, document)


@when("a configuration whose conduit uses another provider's policy is applied")
def step_apply_mismatch(context) -> None:
    document = minimal_configuration()
    document["providers"].append({"id": "codex", "name": "Codex", "enabled": True})
    document["conduits"][0]["provider_id"] = "codex"
    apply(context, document)


@when('a configuration whose provider name holds a synthetic "{rule}" credential is applied')
def step_apply_secret(context, rule: str) -> None:
    context.secret = synthetic_secrets()[rule]
    document = minimal_configuration()
    document["providers"][0]["name"] = f"Claude {context.secret}"
    apply(context, document)


# --- outcomes ---------------------------------------------------------------------------------

@then("the match is eligible")
def step_eligible(context) -> None:
    assert context.result == MatchResult(True, ()), context.result


@then('the match is denied with "{codes}"')
def step_denied(context, codes: str) -> None:
    assert context.result == MatchResult(False, split(codes)), context.result


@then("no snapshot was loaded")
def step_no_snapshot(context) -> None:
    assert context.snapshot is None


@then('the snapshot declares models "{models}" under a "{kind}" policy')
def step_declared(context, models: str, kind: str) -> None:
    policy = context.snapshot.model_policy
    assert (policy.kind, policy.declared_models) == (kind, split(models)), policy


@then("the match result records no actual model")
def step_no_actual_model(context) -> None:
    assert [f.name for f in dataclasses.fields(context.result)] == ["eligible", "reasons"]
    assert not any("actual" in f.name for f in dataclasses.fields(context.snapshot))


@then("the registry holds no receipt, job, claim or lease table")
def step_no_runtime_tables(context) -> None:
    connection = sqlite3.connect(f"file:{context.db}?mode=ro", uri=True)
    try:
        names = [row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type = 'table'")]
    finally:
        connection.close()
    for name in names:
        for word in ("receipt", "job", "claim", "lease", "attempt", "worker"):
            assert word not in name, name


@then("the sandbox holds only the registry database")
def step_only_database(context) -> None:
    assert sorted(p.name for p in context.sandbox.iterdir()) == [context.db.name]


@then("the sandbox is empty")
def step_sandbox_empty(context) -> None:
    assert list(context.sandbox.iterdir()) == []


@then("the schema version is {version:d}")
def step_version(context, version: int) -> None:
    assert context.version == version
    assert dump(context.db)[0] == f"user_version={version}"


@then("the database file is unchanged since the first migration")
def step_unchanged_since_first(context) -> None:
    assert context.db.read_bytes() == context.first_migration


@then("the database file is byte-for-byte unchanged")
def step_bytes_unchanged(context) -> None:
    assert context.db.read_bytes() == context.file_bytes


@then("the registry contents are unchanged")
def step_contents_unchanged(context) -> None:
    assert dump(context.db) == context.baseline


@then('conduit "{conduit_id}" is named "{name}"')
def step_named(context, conduit_id: str, name: str) -> None:
    assert registry.load_conduit(context.db, conduit_id).name == name


@then('the error code is "{code}"')
def step_error_code(context, code: str) -> None:
    assert context.error is not None and context.error.code == code, context.error


@then("the attempt gave up within {limit:d} seconds")
def step_bounded(context, limit: int) -> None:
    assert context.elapsed < limit, context.elapsed


@then("the configuration is {outcome:w}")
def step_configuration(context, outcome: str) -> None:
    assert outcome in ("accepted", "rejected"), outcome
    if outcome == "accepted":
        assert context.error is None, context.error
    else:
        assert isinstance(context.error, registry.ConfigurationError), context.error
        assert context.error.code == "invalid_configuration"


@then('the error names rule "{rule}" without echoing the credential')
def step_no_echo(context, rule: str) -> None:
    message = f"{context.error} {context.error!r}"
    assert rule in message, message
    assert context.secret not in message


@then("the example fixture files match no credential rule")
def step_examples_clean(context) -> None:
    for path in (EXAMPLES, TDD_PROCEDURE):
        assert registry.credential_rules(path.read_text(encoding="utf-8")) == [], path.name


@then("no persisted text column matches a credential rule")
def step_columns_clean(context) -> None:
    connection = sqlite3.connect(f"file:{context.db}?mode=ro", uri=True)
    try:
        tables = [row[0] for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")]
        for table in tables:
            for row in connection.execute(f"SELECT * FROM {table}"):
                for value in row:
                    if isinstance(value, str):
                        assert registry.credential_rules(value) == [], table
    finally:
        connection.close()
