"""conduit-registry.py: JSON on stdout; exit 0 success or eligible, 3 denied or unknown, 2 malformed."""
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

from conduit_test_support import CLI, ROOT, minimal_configuration, sandbox, synthetic_secrets, tdd_integrity


class Cli(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = sandbox(self)
        self.db = self.dir / "registry.sqlite3"

    def run_cli(self, *args: str) -> subprocess.CompletedProcess:
        env = {"PATH": os.environ.get("PATH", ""), "HOME": str(self.dir), "PYTHONDONTWRITEBYTECODE": "1"}
        return subprocess.run([sys.executable, str(CLI), *args], cwd=self.dir, env=env,
                              capture_output=True, text=True, timeout=60)

    def write(self, name: str, document: object) -> Path:
        path = self.dir / name
        path.write_text(json.dumps(document))
        return path

    def seeded(self) -> None:
        self.assertEqual(self.run_cli("migrate", "--database", str(self.db)).returncode, 0)
        self.assertEqual(self.run_cli("seed-examples", "--database", str(self.db)).returncode, 0)

    def match(self, conduit: str, request: object) -> subprocess.CompletedProcess:
        path = self.write("request.json", request)
        return self.run_cli("match", "--database", str(self.db), "--conduit", conduit, "--request", str(path))

    def coding(self) -> dict:
        return {"capabilities": ["coding"], "permissions": ["code", "test"],
                "skills": [{"id": "tdd", "version": "1.0.0", "integrity_sha256": tdd_integrity()}]}

    def test_administration_succeeds_with_json(self) -> None:
        migrated = self.run_cli("migrate", "--database", str(self.db))
        self.assertEqual(migrated.returncode, 0, migrated.stderr)
        self.assertEqual(json.loads(migrated.stdout), {"schema_version": 1})
        seeded = self.run_cli("seed-examples", "--database", str(self.db))
        self.assertEqual(seeded.returncode, 0, seeded.stderr)
        self.assertEqual(json.loads(seeded.stdout), {"seeded": "examples"})
        again = self.run_cli("seed-examples", "--database", str(self.db))
        self.assertEqual(again.returncode, 0, again.stderr)

    def test_eligible_match_exits_zero(self) -> None:
        self.seeded()
        result = self.match("chase", self.coding())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"conduit": "chase", "eligible": True, "reasons": []})

    def test_denied_match_exits_three(self) -> None:
        self.seeded()
        result = self.match("charlie", self.coding())
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual(json.loads(result.stdout)["reasons"],
                         ["missing_capability", "missing_permission", "missing_skill"])

    def test_unknown_conduit_is_a_denial(self) -> None:
        self.seeded()
        result = self.match("nobody", self.coding())
        self.assertEqual(result.returncode, 3)
        self.assertEqual(json.loads(result.stdout)["reasons"], ["unknown_conduit"])

    def test_empty_requirements_are_an_invalid_request_denial(self) -> None:
        self.seeded()
        result = self.match("chase", {"capabilities": [], "permissions": []})
        self.assertEqual(result.returncode, 3)
        self.assertEqual(json.loads(result.stdout)["reasons"], ["invalid_request"])

    def test_malformed_request_exits_two(self) -> None:
        self.seeded()
        for request in (["coding"], {"capabilities": ["coding"]}, {"capabilities": "coding", "permissions": []},
                        {"capabilities": [], "permissions": [], "extra": 1},
                        {"capabilities": [], "permissions": [], "approves_revision": "yes"}):
            with self.subTest(request=request):
                result = self.match("chase", request)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(json.loads(result.stderr)["error"], "malformed_request")
        bad = self.dir / "bad.json"
        bad.write_text("{not json")
        result = self.run_cli("match", "--database", str(self.db), "--conduit", "chase", "--request", str(bad))
        self.assertEqual(result.returncode, 2)

    def test_storage_and_schema_failures_exit_two(self) -> None:
        missing = self.run_cli("show", "--database", str(self.dir / "absent.sqlite3"), "--conduit", "chase")
        self.assertEqual(missing.returncode, 2)
        self.assertEqual(json.loads(missing.stderr)["error"], "missing_database")
        self.assertFalse((self.dir / "absent.sqlite3").exists())
        relative = self.run_cli("migrate", "--database", "registry.sqlite3")
        self.assertEqual(relative.returncode, 2)
        inside = self.run_cli("migrate", "--database", str(ROOT / "registry.sqlite3"))
        self.assertEqual(inside.returncode, 2)
        self.assertEqual(json.loads(inside.stderr)["error"], "invalid_path")
        self.assertFalse((ROOT / "registry.sqlite3").exists())
        unmigrated = self.run_cli("seed-examples", "--database", str(self.db))
        self.assertEqual(unmigrated.returncode, 2)

    def test_show_prints_the_snapshot(self) -> None:
        self.seeded()
        shown = self.run_cli("show", "--database", str(self.db), "--conduit", "chase")
        self.assertEqual(shown.returncode, 0, shown.stderr)
        snapshot = json.loads(shown.stdout)["conduit"]
        self.assertEqual(snapshot["model_policy"]["declared_models"], ["sonnet"])
        self.assertNotIn("actual_model", shown.stdout)
        unknown = self.run_cli("show", "--database", str(self.db), "--conduit", "nobody")
        self.assertEqual(unknown.returncode, 3)
        self.assertIsNone(json.loads(unknown.stdout)["conduit"])

    def test_apply_rejects_credentials_without_echoing_them(self) -> None:
        self.assertEqual(self.run_cli("migrate", "--database", str(self.db)).returncode, 0)
        for rule, secret in synthetic_secrets().items():
            with self.subTest(rule=rule):
                document = minimal_configuration()
                document["providers"][0]["name"] = secret
                path = self.write("config.json", document)
                result = self.run_cli("apply", "--database", str(self.db), "--config", str(path))
                self.assertEqual(result.returncode, 2)
                self.assertEqual(json.loads(result.stderr)["error"], "invalid_configuration")
                self.assertNotIn(secret, result.stdout + result.stderr)
        good = self.write("config.json", minimal_configuration())
        applied = self.run_cli("apply", "--database", str(self.db), "--config", str(good))
        self.assertEqual(applied.returncode, 0, applied.stderr)


if __name__ == "__main__":
    unittest.main()
