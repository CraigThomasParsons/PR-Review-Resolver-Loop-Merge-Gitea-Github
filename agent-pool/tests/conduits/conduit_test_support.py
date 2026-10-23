"""Shared helpers for the Conduit registry tests: checkout paths, sandboxes and synthetic secrets.

Importing this module puts agent-pool/scripts on sys.path, so the tests run the same with or
without PYTHONPATH=agent-pool/scripts. Sandboxes live in the system temp directory, never in
the checkout, and are removed when the test ends.
"""
import hashlib
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = ROOT / "agent-pool" / "scripts"
TESTS = ROOT / "agent-pool" / "tests"
EXAMPLES = ROOT / "agent-pool" / "config" / "conduits.example.json"
TDD_PROCEDURE = ROOT / "agent-pool" / "config" / "skills" / "tdd.md"
CLI = SCRIPTS / "conduit-registry.py"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))


def sandbox(case: unittest.TestCase) -> Path:
    directory = Path(tempfile.mkdtemp(prefix="conduit-test-")).resolve()
    case.addCleanup(shutil.rmtree, directory, True)
    return directory


def tdd_integrity() -> str:
    return hashlib.sha256(TDD_PROCEDURE.read_bytes()).hexdigest()


def synthetic_secrets() -> dict[str, str]:
    """One credential-shaped placeholder per scanner rule, assembled at run time so that no
    realistic key is ever committed. None of them is a real credential."""
    return {
        "private-key": "-----BEGIN " + "OPENSSH PRIVATE" + " KEY-----",
        "provider-token": "sk-" + "ant-" + "placeholder" + "0" * 24,
        "credential-assignment": "api" + "_key = " + "placeholder" + "0123456789abcdef",
    }


def minimal_configuration() -> dict:
    """A small, valid, self-contained configuration for tests that need their own conduits."""
    return {
        "format": "conduit-registry/v1",
        "providers": [{"id": "claude", "name": "Claude", "enabled": True}],
        "model_policies": [
            {"id": "claude-auto", "provider_id": "claude", "kind": "auto", "models": [], "enabled": True},
        ],
        "capabilities": [
            {"id": "coding", "name": "Coding", "enabled": True},
            {"id": "reviewing", "name": "Reviewing", "enabled": True},
        ],
        "permissions": [
            {"id": "code", "name": "Write code", "enabled": True},
            {"id": "review", "name": "Publish a review", "enabled": True},
        ],
        "skills": [],
        "conduits": [
            {
                "id": "dual",
                "name": "Dual (test only)",
                "provider_id": "claude",
                "model_policy_id": "claude-auto",
                "executable": "claude",
                "invocation": ["claude"],
                "enabled": True,
                "capabilities": ["coding", "reviewing"],
                "permissions": ["code", "review"],
                "skills": [],
            }
        ],
    }
