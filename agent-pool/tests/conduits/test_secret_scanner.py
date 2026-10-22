"""scan-conduit-secrets.py: changed filenames and added text between two commits.

Each case builds a throwaway repository in a temporary directory with an isolated git
configuration. Credential-shaped fixtures are synthetic placeholders assembled at run time.
"""
import os
import subprocess
import sys
import unittest
from pathlib import Path

from conduit_test_support import TESTS, sandbox, synthetic_secrets

SCANNER = TESTS / "scan-conduit-secrets.py"


class Repository:
    def __init__(self, path: Path) -> None:
        self.path = path
        home = path.parent / "git-home"
        home.mkdir(exist_ok=True)
        self.env = {"PATH": os.environ.get("PATH", ""), "HOME": str(home), "GIT_CONFIG_NOSYSTEM": "1",
                    "GIT_CONFIG_GLOBAL": os.devnull, "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "t@example.invalid",
                    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "t@example.invalid"}
        self.git("init", "-q", "-b", "main")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", *args],
                              cwd=self.path, env=self.env, check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, files: dict[str, bytes | str | None]) -> str:
        for name, content in files.items():
            target = self.path / name
            if content is None:
                self.git("rm", "-q", "--", name)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content if isinstance(content, bytes) else content.encode())
            self.git("add", "--", name)
        self.git("commit", "-q", "--allow-empty", "-m", "change")
        return self.git("rev-parse", "HEAD")

    def scan(self, base: str, head: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(SCANNER), "--base", base, "--head", head, "--repo", str(self.path)],
                              env=self.env, capture_output=True, text=True, timeout=60)


class Scanner(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = Repository(self.make_dir())
        self.base = self.repo.commit({"README": "base\n", "old.txt": "keep\n"})
        self.secrets = synthetic_secrets()

    def make_dir(self) -> Path:
        path = sandbox(self) / "repo"
        path.mkdir()
        return path

    def findings(self, ran: subprocess.CompletedProcess) -> set[tuple[str, str]]:
        return {tuple(line.split("\t")) for line in ran.stdout.splitlines() if line}

    def assert_clean_output(self, ran: subprocess.CompletedProcess) -> None:
        for secret in self.secrets.values():
            self.assertNotIn(secret, ran.stdout + ran.stderr)

    def test_each_content_rule_is_reported_by_path_and_rule_only(self) -> None:
        head = self.repo.commit({f"{rule}.txt": f"line one\n{secret}\n" for rule, secret in self.secrets.items()})
        ran = self.repo.scan(self.base, head)
        self.assertEqual(ran.returncode, 1, ran.stderr)
        self.assertEqual(self.findings(ran), {(f"{rule}.txt", rule) for rule in self.secrets})
        self.assert_clean_output(ran)

    def test_credential_reference_metadata_is_accepted(self) -> None:
        head = self.repo.commit({"conduits.json": '{"credential_ref": "vault:claude/api-key",\n'
                                                  ' "api_key_env": "ANTHROPIC_API_KEY",\n'
                                                  ' "token_file": "~/.config/pulse/gitea_token",\n'
                                                  ' "integrity_sha256": "' + "ab" * 32 + '"}\n'})
        ran = self.repo.scan(self.base, head)
        self.assertEqual((ran.returncode, ran.stdout), (0, ""), ran.stderr)

    def test_forbidden_filenames(self) -> None:
        for name in (".env", "config/.env.local", "gitea_token", "keys/id_rsa", "server.pem", "tls.key"):
            with self.subTest(name=name):
                base = self.repo.git("rev-parse", "HEAD")
                head = self.repo.commit({name: "harmless\n"})
                ran = self.repo.scan(base, head)
                self.assertEqual(ran.returncode, 1)
                self.assertEqual(self.findings(ran), {(name, "filename")})

    def test_only_added_lines_are_scanned(self) -> None:
        secret = self.secrets["provider-token"]
        base = self.repo.commit({"notes.txt": f"{secret}\n"})
        head = self.repo.commit({"notes.txt": f"{secret}\nnew line\n"})
        ran = self.repo.scan(base, head)
        self.assertEqual((ran.returncode, ran.stdout), (0, ""))

    def test_deleted_files_are_skipped(self) -> None:
        base = self.repo.commit({"notes.txt": self.secrets["private-key"] + "\n", "id_rsa": "x\n"})
        head = self.repo.commit({"notes.txt": None, "id_rsa": None})
        ran = self.repo.scan(base, head)
        self.assertEqual((ran.returncode, ran.stdout), (0, ""))

    def test_renames_are_scanned_under_the_new_name(self) -> None:
        body = "".join(f"line {i}\n" for i in range(40))
        base = self.repo.commit({"plain.txt": body})
        head = self.repo.commit({"plain.txt": None, "moved.txt": body + self.secrets["provider-token"] + "\n"})
        ran = self.repo.scan(base, head)
        self.assertEqual(self.findings(ran), {("moved.txt", "provider-token")})
        base = head
        head = self.repo.commit({"moved.txt": None, "renamed.pem": body + self.secrets["provider-token"] + "\n"})
        ran = self.repo.scan(base, head)
        self.assertEqual(self.findings(ran), {("renamed.pem", "filename")})

    def test_binary_content_is_scanned_whole(self) -> None:
        payload = b"\x00\x01binary\x00" + self.secrets["private-key"].encode() + b"\x00"
        head = self.repo.commit({"blob.bin": payload, "clean.bin": b"\x00\x01\x02"})
        ran = self.repo.scan(self.base, head)
        self.assertEqual(ran.returncode, 1)
        self.assertEqual(self.findings(ran), {("blob.bin", "private-key")})
        self.assert_clean_output(ran)

    def test_unreadable_changed_content_fails_closed(self) -> None:
        self.repo.git("update-index", "--add", "--cacheinfo", f"160000,{self.base},vendored")
        head = self.repo.commit({})
        ran = self.repo.scan(self.base, head)
        self.assertEqual(ran.returncode, 2)

    def test_unknown_revision_fails(self) -> None:
        ran = self.repo.scan("0" * 40, self.base)
        self.assertEqual(ran.returncode, 2)
        ran = self.repo.scan(self.base, "not-a-revision")
        self.assertEqual(ran.returncode, 2)

    def test_no_change_is_clean(self) -> None:
        ran = self.repo.scan(self.base, self.base)
        self.assertEqual((ran.returncode, ran.stdout), (0, ""))


if __name__ == "__main__":
    unittest.main()
