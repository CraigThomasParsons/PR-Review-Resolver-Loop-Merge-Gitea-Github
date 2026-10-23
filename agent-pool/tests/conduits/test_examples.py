"""The committed example fixture (Charlie, Chase, the TDD procedure) and the Behave lockfile."""
import json
import re
import unittest

from conduit_test_support import EXAMPLES, TDD_PROCEDURE, TESTS, tdd_integrity
import conduit_registry as registry

LOCKFILE = TESTS / "requirements-conduits.lock"


def strings(node: object) -> list[str]:
    if isinstance(node, str):
        return [node]
    if isinstance(node, dict):
        return [s for key, value in node.items() for s in (key, *strings(value))]
    if isinstance(node, list):
        return [s for item in node for s in strings(item)]
    return []


class Examples(unittest.TestCase):
    def setUp(self) -> None:
        self.document = json.loads(EXAMPLES.read_text(encoding="utf-8"))
        self.conduits = {c["id"]: c for c in self.document["conduits"]}
        self.policies = {p["id"]: p for p in self.document["model_policies"]}

    def test_example_files_are_secret_free(self) -> None:
        for path in (EXAMPLES, TDD_PROCEDURE):
            self.assertEqual(registry.credential_rules(path.read_text(encoding="utf-8")), [], path.name)
        for value in strings(self.document):
            self.assertEqual(registry.credential_rules(value), [])

    def test_skill_integrity_is_derived_from_the_procedure_bytes(self) -> None:
        skills = registry.example_configuration()["skills"]
        self.assertEqual([(s["id"], s["version"], s["integrity_sha256"]) for s in skills],
                         [("tdd", "1.0.0", tdd_integrity())])
        self.assertNotIn("integrity_sha256", json.dumps(self.document))

    def test_charlie(self) -> None:
        charlie = self.conduits["charlie"]
        self.assertEqual(charlie["provider_id"], "claude")
        self.assertEqual(self.policies[charlie["model_policy_id"]]["kind"], "auto")
        self.assertEqual(self.policies[charlie["model_policy_id"]]["models"], [])
        self.assertEqual(sorted(charlie["capabilities"]), ["planning", "reviewing"])
        self.assertEqual(sorted(charlie["permissions"]), ["plan", "review"])
        self.assertEqual(charlie["skills"], [])

    def test_chase(self) -> None:
        chase = self.conduits["chase"]
        self.assertEqual(chase["provider_id"], "claude")
        self.assertEqual(self.policies[chase["model_policy_id"]]["kind"], "fixed")
        self.assertEqual(self.policies[chase["model_policy_id"]]["models"], ["sonnet"])
        self.assertEqual(chase["capabilities"], ["coding"])
        self.assertEqual(sorted(chase["permissions"]), ["code", "test"])
        self.assertEqual(chase["skills"], [{"id": "tdd", "version": "1.0.0"}])

    def test_both_declare_claude_and_neither_may_merge(self) -> None:
        self.assertEqual(set(self.conduits), {"charlie", "chase"})
        for conduit in self.conduits.values():
            self.assertEqual((conduit["executable"], conduit["invocation"]), ("claude", ["claude"]))
            self.assertNotIn("merge", conduit["permissions"])
            self.assertTrue(conduit["enabled"])


class SliceFiles(unittest.TestCase):
    def test_no_conduit_file_matches_a_credential_rule(self) -> None:
        root = TESTS.parents[1]
        files = [root / "agent-pool/scripts/conduit_registry.py", root / "agent-pool/scripts/conduit-registry.py",
                 root / "agent-pool/tests/verify-conduits.sh", root / "agent-pool/tests/scan-conduit-secrets.py",
                 root / "agent-pool/tests/check-behave-result.py", LOCKFILE, root / "docs/plans/conduit-registry.md",
                 *sorted((TESTS / "conduits").glob("*.py")), *sorted((TESTS / "features").rglob("*.py")),
                 *sorted((TESTS / "features").glob("*.feature"))]
        for path in files:
            with self.subTest(path=path.relative_to(root)):
                self.assertEqual(registry.credential_rules(path.read_text(encoding="utf-8")), [])


class Lockfile(unittest.TestCase):
    def test_every_requirement_is_pinned_with_sha256_hashes(self) -> None:
        text = LOCKFILE.read_text(encoding="utf-8")
        entries = re.split(r"\n(?=[A-Za-z])", "\n".join(
            line for line in text.splitlines() if not line.startswith("#")).strip())
        pins = {}
        for entry in entries:
            head = entry.split()[0]
            name, _, version = head.partition("==")
            self.assertTrue(version, f"{head} is not pinned with ==")
            hashes = re.findall(r"--hash=sha256:([0-9a-f]+)", entry)
            self.assertTrue(hashes, f"{name} has no hash")
            for digest in hashes:
                self.assertEqual(len(digest), 64)
            pins[name] = version
        self.assertEqual(pins, {"behave": "1.3.3", "colorama": "0.4.6", "cucumber-expressions": "20.1.0",
                                "cucumber-tag-expressions": "11.0.1", "parse": "1.22.3",
                                "parse-type": "0.6.6", "six": "1.17.0"})


if __name__ == "__main__":
    unittest.main()
