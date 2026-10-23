"""SQLite integration: migration, seeding, the application API, constraints, transactions and reads.

Every database lives in a temporary directory outside the checkout. Raw sqlite3 connections are
used only to build hostile fixtures (a newer schema, a foreign table) and to dump state.
"""
import contextlib
import copy
import os
import sqlite3
import subprocess
import sys
import time
import unittest
from collections.abc import Iterator
from pathlib import Path
from unittest import mock

from conduit_test_support import (
    ROOT, SCRIPTS, minimal_configuration, sandbox, synthetic_secrets, tdd_integrity,
)
import conduit_registry as registry
from conduit_registry import MatchRequest, SkillRequirement, match_conduit

DOMAIN_TABLES = {
    "providers", "model_policies", "model_policy_models", "conduits", "capabilities", "skills",
    "permissions", "conduit_capabilities", "conduit_permissions", "conduit_skills",
}


def dump(path: Path) -> list[str]:
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        version = connection.execute("PRAGMA user_version").fetchone()[0]
        return [f"user_version={version}", *connection.iterdump()]
    finally:
        connection.close()


@contextlib.contextmanager
def raw(path: Path) -> Iterator[sqlite3.Connection]:
    connection = sqlite3.connect(str(path), isolation_level=None)
    try:
        yield connection
    finally:
        connection.close()


class Case(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = sandbox(self)
        self.db = self.dir / "registry.sqlite3"

    def seeded(self) -> Path:
        registry.migrate(self.db)
        registry.seed_examples(self.db)
        return self.db

    def assert_code(self, raised: BaseException, code: str) -> None:
        self.assertIsInstance(raised, registry.RegistryError)
        self.assertEqual(raised.code, code)


class Migration(Case):
    def test_new_database_migrates_to_version_one(self) -> None:
        self.assertEqual(registry.migrate(self.db), 1)
        with raw(self.db) as connection:
            self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 1)
            tables = {row[0] for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")}
        self.assertEqual(tables, DOMAIN_TABLES)

    def test_no_job_claim_lease_or_receipt_tables(self) -> None:
        registry.migrate(self.db)
        for table in DOMAIN_TABLES:
            for word in ("job", "claim", "lease", "fence", "worker", "receipt", "attempt", "schedule"):
                self.assertNotIn(word, table)

    def test_repeat_migration_is_a_no_op(self) -> None:
        registry.migrate(self.db)
        before = self.db.read_bytes()
        self.assertEqual(registry.migrate(self.db), 1)
        self.assertEqual(self.db.read_bytes(), before)

    def test_newer_schema_is_refused_without_mutation(self) -> None:
        with raw(self.db) as connection:
            connection.execute("CREATE TABLE future (x)")
            connection.execute("PRAGMA user_version = 2")
        before = self.db.read_bytes()
        with self.assertRaises(registry.SchemaError) as caught:
            registry.migrate(self.db)
        self.assert_code(caught.exception, "unsupported_schema")
        self.assertEqual(self.db.read_bytes(), before)

    def test_unversioned_foreign_database_is_refused_without_mutation(self) -> None:
        with raw(self.db) as connection:
            connection.execute("CREATE TABLE something_else (x)")
        before = self.db.read_bytes()
        with self.assertRaises(registry.SchemaError) as caught:
            registry.migrate(self.db)
        self.assert_code(caught.exception, "unsupported_schema")
        self.assertEqual(self.db.read_bytes(), before)

    def test_not_a_database_is_a_storage_error(self) -> None:
        self.db.write_bytes(b"this is not sqlite" * 100)
        with self.assertRaises(registry.StorageError):
            registry.migrate(self.db)

    def test_relative_path_is_refused(self) -> None:
        with self.assertRaises(registry.InvalidPathError):
            registry.migrate(Path("registry.sqlite3"))

    def test_path_inside_the_checkout_is_refused_and_not_created(self) -> None:
        inside = ROOT / "agent-pool" / "conduit-test-should-not-exist.sqlite3"
        for operation in (registry.migrate, registry.seed_examples):
            with self.assertRaises(registry.InvalidPathError):
                operation(inside)
        with self.assertRaises(registry.InvalidPathError):
            registry.load_conduit(inside, "charlie")
        self.assertFalse(inside.exists())

    def test_missing_directory_is_refused(self) -> None:
        with self.assertRaises(registry.InvalidPathError):
            registry.migrate(self.dir / "absent" / "registry.sqlite3")

    def test_import_creates_nothing(self) -> None:
        home = self.dir / "home"
        home.mkdir()
        env = {"PATH": os.environ.get("PATH", ""), "HOME": str(home), "PYTHONPATH": str(SCRIPTS),
               "PYTHONDONTWRITEBYTECODE": "1"}
        subprocess.run([sys.executable, "-c", "import conduit_registry"], cwd=self.dir, env=env, check=True)
        self.assertEqual(sorted(p.name for p in self.dir.iterdir()), ["home"])
        self.assertEqual(list(home.iterdir()), [])

    def test_connections_enforce_foreign_keys_and_a_bounded_busy_timeout(self) -> None:
        registry.migrate(self.db)
        self.assertEqual(registry.BUSY_TIMEOUT_SECONDS, 5.0)
        with registry.admin_transaction(self.db) as connection:
            self.assertEqual(connection.execute("PRAGMA foreign_keys").fetchone()[0], 1)
            self.assertEqual(connection.execute("PRAGMA busy_timeout").fetchone()[0], 5000)


class Seeding(Case):
    def test_seed_loads_charlie_and_chase(self) -> None:
        self.seeded()
        charlie = registry.load_conduit(self.db, "charlie")
        chase = registry.load_conduit(self.db, "chase")
        self.assertEqual(charlie.provider_id, "claude")
        self.assertEqual(charlie.model_policy.kind, "auto")
        self.assertEqual(charlie.model_policy.declared_models, ())
        self.assertEqual([g.id for g in charlie.capabilities], ["planning", "reviewing"])
        self.assertEqual([g.id for g in charlie.permissions], ["plan", "review"])
        self.assertEqual(charlie.skills, ())
        self.assertEqual(chase.model_policy.kind, "fixed")
        self.assertEqual(chase.model_policy.declared_models, ("sonnet",))
        self.assertEqual([g.id for g in chase.capabilities], ["coding"])
        self.assertEqual([g.id for g in chase.permissions], ["code", "test"])
        self.assertEqual([(s.id, s.version, s.integrity_sha256) for s in chase.skills],
                         [("tdd", "1.0.0", tdd_integrity())])
        for conduit in (charlie, chase):
            self.assertEqual((conduit.executable, conduit.invocation), ("claude", ("claude",)))
            self.assertNotIn("merge", [g.id for g in conduit.permissions])

    def test_repeat_identical_seed_is_a_no_op(self) -> None:
        self.seeded()
        before = dump(self.db)
        registry.seed_examples(self.db)
        self.assertEqual(dump(self.db), before)

    def test_conflicting_row_fails_without_overwriting_the_operator_edit(self) -> None:
        self.seeded()
        with registry.admin_transaction(self.db) as connection:
            connection.execute("UPDATE conduits SET name = 'Charlie (edited)' WHERE id = 'charlie'")
        before = dump(self.db)
        with self.assertRaises(registry.ConflictError) as caught:
            registry.seed_examples(self.db)
        self.assert_code(caught.exception, "conflict")
        self.assertEqual(dump(self.db), before)

    def test_conflicting_grant_set_fails_without_change(self) -> None:
        self.seeded()
        with registry.admin_transaction(self.db) as connection:
            connection.execute("INSERT INTO conduit_permissions VALUES ('charlie', 'code')")
        before = dump(self.db)
        with self.assertRaises(registry.ConflictError):
            registry.seed_examples(self.db)
        self.assertEqual(dump(self.db), before)

    def test_conflicting_policy_models_fail_without_change(self) -> None:
        self.seeded()
        with registry.admin_transaction(self.db) as connection:
            connection.execute("UPDATE model_policies SET kind = 'allow_list' WHERE id = 'claude-sonnet'")
            connection.execute("INSERT INTO model_policy_models VALUES ('claude-sonnet', 'opus')")
        before = dump(self.db)
        with self.assertRaises(registry.ConflictError):
            registry.seed_examples(self.db)
        self.assertEqual(dump(self.db), before)

    def test_seed_needs_a_migrated_database(self) -> None:
        with raw(self.db) as connection:
            connection.execute("PRAGMA user_version = 0")
        with self.assertRaises(registry.SchemaError) as caught:
            registry.seed_examples(self.db)
        self.assert_code(caught.exception, "schema_missing")

    def test_seed_does_not_create_a_missing_database(self) -> None:
        with self.assertRaises(registry.RegistryNotFoundError):
            registry.seed_examples(self.db)
        self.assertFalse(self.db.exists())

    def test_persisted_text_is_secret_free(self) -> None:
        self.seeded()
        with raw(self.db) as connection:
            for table in DOMAIN_TABLES:
                for row in connection.execute(f"SELECT * FROM {table}"):
                    for value in row:
                        if isinstance(value, str):
                            self.assertEqual(registry.credential_rules(value), [], table)


class ApplicationApi(Case):
    def setUp(self) -> None:
        super().setUp()
        registry.migrate(self.db)
        self.empty = dump(self.db)

    def assert_rejected(self, document: dict) -> registry.ConfigurationError:
        with self.assertRaises(registry.ConfigurationError) as caught:
            registry.apply_configuration(self.db, document)
        self.assert_code(caught.exception, "invalid_configuration")
        self.assertEqual(dump(self.db), self.empty)
        return caught.exception

    def test_minimal_configuration_applies(self) -> None:
        registry.apply_configuration(self.db, minimal_configuration())
        self.assertEqual(registry.load_conduit(self.db, "dual").name, "Dual (test only)")

    def test_policy_cardinality_is_enforced(self) -> None:
        for kind, models in (("fixed", []), ("fixed", ["opus", "sonnet"]), ("allow_list", []),
                             ("auto", ["sonnet"]), ("random", []), ("allow_list", ["sonnet", "sonnet"])):
            with self.subTest(kind=kind, models=models):
                document = minimal_configuration()
                document["model_policies"][0].update(kind=kind, models=models)
                self.assert_rejected(document)

    def test_valid_cardinalities_apply(self) -> None:
        document = minimal_configuration()
        document["model_policies"] += [
            {"id": "fixed", "provider_id": "claude", "kind": "fixed", "models": ["sonnet"], "enabled": True},
            {"id": "listed", "provider_id": "claude", "kind": "allow_list", "models": ["opus", "sonnet"],
             "enabled": True},
        ]
        registry.apply_configuration(self.db, document)

    def test_policy_provider_mismatch_is_rejected(self) -> None:
        document = minimal_configuration()
        document["providers"].append({"id": "codex", "name": "Codex", "enabled": True})
        document["conduits"][0]["provider_id"] = "codex"
        self.assert_rejected(document)

    def test_structural_errors_are_rejected(self) -> None:
        def broken(change):
            document = minimal_configuration()
            change(document)
            return document

        cases = {
            "unknown top-level key": lambda d: d.update(metadata={}),
            "wrong format": lambda d: d.update(format="conduit-registry/v2"),
            "unknown row key": lambda d: d["providers"][0].update(api_key_ref="x"),
            "missing row key": lambda d: d["providers"][0].pop("enabled"),
            "uppercase id": lambda d: d["capabilities"][0].update(id="Coding"),
            "blank name": lambda d: d["capabilities"][0].update(name="  "),
            "integer enabled": lambda d: d["capabilities"][0].update(enabled=1),
            "duplicate id": lambda d: d["capabilities"].append(dict(d["capabilities"][0])),
            "unknown capability grant": lambda d: d["conduits"][0]["capabilities"].append("planning"),
            "duplicate grant": lambda d: d["conduits"][0]["permissions"].append("code"),
            "unknown provider": lambda d: d["model_policies"][0].update(provider_id="nobody"),
            "unknown policy": lambda d: d["conduits"][0].update(model_policy_id="nobody"),
            "empty invocation": lambda d: d["conduits"][0].update(invocation=[]),
            "argv0 differs": lambda d: d["conduits"][0].update(invocation=["sh", "-c", "claude"]),
            "non-string argument": lambda d: d["conduits"][0].update(invocation=["claude", 1]),
            "bad integrity": lambda d: d["skills"].append(
                {"id": "tdd", "version": "1.0.0", "name": "TDD", "integrity_sha256": "ABC", "enabled": True}),
            "unknown skill grant": lambda d: d["conduits"][0].update(skills=[{"id": "tdd", "version": "1.0.0"}]),
            "not an object": lambda d: d.update(providers=["claude"]),
        }
        for name, change in cases.items():
            with self.subTest(name):
                self.assert_rejected(broken(change))
        with self.subTest("not a document"):
            with self.assertRaises(registry.ConfigurationError):
                registry.apply_configuration(self.db, ["not", "a", "mapping"])

    def test_credential_shaped_input_is_rejected_without_echo(self) -> None:
        for rule, secret in synthetic_secrets().items():
            for place in ("provider name", "invocation argument"):
                with self.subTest(rule=rule, place=place):
                    document = minimal_configuration()
                    if place == "provider name":
                        document["providers"][0]["name"] = f"Claude {secret}"
                    else:
                        document["conduits"][0]["invocation"] = ["claude", secret]
                    error = self.assert_rejected(document)
                    self.assertNotIn(secret, str(error))
                    self.assertNotIn(secret, repr(error))
                    self.assertIn(rule, str(error))

    def test_input_is_not_mutated(self) -> None:
        document = minimal_configuration()
        original = copy.deepcopy(document)
        registry.apply_configuration(self.db, document)
        self.assertEqual(document, original)


class Constraints(Case):
    def setUp(self) -> None:
        super().setUp()
        self.seeded()
        self.before = dump(self.db)

    def assert_constraint(self, *statements: str) -> None:
        with self.assertRaises(registry.ConstraintError) as caught:
            with registry.admin_transaction(self.db) as connection:
                for statement in statements:
                    connection.execute(statement)
        self.assert_code(caught.exception, "constraint_violation")
        self.assertEqual(dump(self.db), self.before)

    def test_foreign_keys(self) -> None:
        self.assert_constraint("INSERT INTO conduit_capabilities VALUES ('charlie', 'nonexistent')")
        self.assert_constraint("INSERT INTO conduit_skills VALUES ('charlie', 'tdd', '9.9.9')")
        self.assert_constraint("INSERT INTO model_policies VALUES ('p', 'nobody', 'auto', 1)")

    def test_restricted_deletion(self) -> None:
        self.assert_constraint("DELETE FROM providers WHERE id = 'claude'")
        self.assert_constraint("DELETE FROM capabilities WHERE id = 'planning'")
        self.assert_constraint("DELETE FROM skills WHERE id = 'tdd'")
        self.assert_constraint("DELETE FROM model_policies WHERE id = 'claude-auto'")

    def test_policy_and_provider_must_agree(self) -> None:
        self.assert_constraint("INSERT INTO providers VALUES ('codex', 'Codex', 1)",
                               "UPDATE conduits SET provider_id = 'codex' WHERE id = 'chase'")

    def test_uniqueness(self) -> None:
        self.assert_constraint("INSERT INTO providers VALUES ('claude', 'Again', 1)")
        self.assert_constraint("INSERT INTO conduit_permissions VALUES ('chase', 'code')")
        self.assert_constraint("INSERT INTO model_policy_models VALUES ('claude-sonnet', 'sonnet')")

    def test_checks(self) -> None:
        self.assert_constraint("UPDATE providers SET enabled = 2")
        self.assert_constraint("UPDATE providers SET enabled = 'yes'")
        self.assert_constraint("UPDATE capabilities SET name = ' ' WHERE id = 'coding'")
        self.assert_constraint("INSERT INTO capabilities VALUES ('Upper', 'Upper', 1)")
        self.assert_constraint("UPDATE skills SET integrity_sha256 = upper(integrity_sha256)")
        self.assert_constraint("UPDATE model_policies SET kind = 'random' WHERE id = 'claude-auto'")
        self.assert_constraint("UPDATE conduits SET invocation_json = '[\"other\"]' WHERE id = 'chase'")
        self.assert_constraint("UPDATE conduits SET invocation_json = '[]' WHERE id = 'chase'")
        self.assert_constraint("UPDATE conduits SET invocation_json = 'claude' WHERE id = 'chase'")


class Transactions(Case):
    def test_interrupted_seed_rolls_back_everything(self) -> None:
        registry.migrate(self.db)
        empty = dump(self.db)
        real = registry._insert_row
        calls = []

        def interrupted(*args: object) -> None:
            calls.append(args)
            if len(calls) == 6:
                raise KeyboardInterrupt("simulated interruption")
            real(*args)

        with mock.patch.object(registry, "_insert_row", interrupted):
            with self.assertRaises(KeyboardInterrupt):
                registry.seed_examples(self.db)
        self.assertEqual(len(calls), 6)
        self.assertEqual(dump(self.db), empty)
        registry.seed_examples(self.db)
        self.assertIsNotNone(registry.load_conduit(self.db, "chase"))

    def test_admin_transaction_rolls_back_on_error(self) -> None:
        self.seeded()
        before = dump(self.db)
        with self.assertRaises(RuntimeError):
            with registry.admin_transaction(self.db) as connection:
                connection.execute("UPDATE conduits SET enabled = 0")
                raise RuntimeError("stop")
        self.assertEqual(dump(self.db), before)

    def test_lock_contention_is_bounded(self) -> None:
        registry.migrate(self.db)
        with raw(self.db) as holder:
            holder.execute("BEGIN IMMEDIATE")
            with mock.patch.object(registry, "BUSY_TIMEOUT_SECONDS", 0.3):
                started = time.monotonic()
                with self.assertRaises(registry.RegistryBusyError) as caught:
                    registry.seed_examples(self.db)
                elapsed = time.monotonic() - started
            holder.execute("ROLLBACK")
        self.assert_code(caught.exception, "busy")
        self.assertGreaterEqual(elapsed, 0.25)
        self.assertLess(elapsed, 3.0)
        registry.seed_examples(self.db)


class Reads(Case):
    def test_missing_file_is_refused_and_not_created(self) -> None:
        with self.assertRaises(registry.RegistryNotFoundError) as caught:
            registry.load_conduit(self.db, "charlie")
        self.assert_code(caught.exception, "missing_database")
        self.assertFalse(self.db.exists())

    def test_unmigrated_schema_is_refused(self) -> None:
        with raw(self.db) as connection:
            connection.execute("CREATE TABLE t (x)")
        with self.assertRaises(registry.SchemaError) as caught:
            registry.load_conduit(self.db, "charlie")
        self.assert_code(caught.exception, "schema_missing")

    def test_unsupported_schema_is_refused_without_mutation(self) -> None:
        self.seeded()
        with raw(self.db) as connection:
            connection.execute("PRAGMA user_version = 2")
        before = self.db.read_bytes()
        with self.assertRaises(registry.SchemaError) as caught:
            registry.load_conduit(self.db, "charlie")
        self.assert_code(caught.exception, "unsupported_schema")
        self.assertEqual(self.db.read_bytes(), before)

    def test_unknown_or_malformed_conduit_is_none(self) -> None:
        self.seeded()
        self.assertIsNone(registry.load_conduit(self.db, "nobody"))
        self.assertIsNone(registry.load_conduit(self.db, "Charlie"))
        self.assertIsNone(registry.load_conduit(self.db, "charlie' OR '1'='1"))

    def test_reads_open_read_only(self) -> None:
        self.seeded()
        before = self.db.read_bytes()
        self.db.chmod(0o444)
        self.addCleanup(self.db.chmod, 0o644)
        self.assertIsNotNone(registry.load_conduit(self.db, "charlie"))
        self.assertEqual(self.db.read_bytes(), before)
        self.assertEqual(sorted(p.name for p in self.dir.iterdir()), ["registry.sqlite3"])

    def test_reads_revalidate_policy_cardinality(self) -> None:
        self.seeded()
        with registry.admin_transaction(self.db) as connection:
            connection.execute("DELETE FROM model_policy_models WHERE model_policy_id = 'claude-sonnet'")
        chase = registry.load_conduit(self.db, "chase")
        self.assertEqual(chase.model_policy.declared_models, ())
        request = MatchRequest(("coding",), ("code", "test"),
                               (SkillRequirement("tdd", "1.0.0", tdd_integrity()),))
        self.assertEqual(match_conduit(chase, request).reasons, ("invalid_model_policy",))

    def test_disabled_rows_are_reported_in_the_snapshot(self) -> None:
        self.seeded()
        with registry.admin_transaction(self.db) as connection:
            connection.execute("UPDATE skills SET enabled = 0 WHERE id = 'tdd'")
            connection.execute("UPDATE providers SET enabled = 0")
        chase = registry.load_conduit(self.db, "chase")
        self.assertFalse(chase.provider.enabled)
        self.assertFalse(chase.skills[0].enabled)

    def test_matching_a_loaded_snapshot_writes_nothing(self) -> None:
        self.seeded()
        state = self.dir / "state"
        with mock.patch.dict(os.environ, {"AGENT_POOL_STATE": str(state)}):
            chase = registry.load_conduit(self.db, "chase")
            before = sorted(p.name for p in self.dir.iterdir())
            request = MatchRequest(("coding",), ("code", "test"),
                                   (SkillRequirement("tdd", "1.0.0", tdd_integrity()),))
            self.assertTrue(match_conduit(chase, request).eligible)
        self.assertEqual(sorted(p.name for p in self.dir.iterdir()), before)
        self.assertFalse(state.exists())


if __name__ == "__main__":
    unittest.main()
