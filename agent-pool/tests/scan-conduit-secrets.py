#!/usr/bin/env python3
"""scan-conduit-secrets.py: scan one diff's changed filenames and added content for credentials.

Usage: scan-conduit-secrets.py --base BASE_SHA --head HEAD_SHA [--repo DIR]

Exit 0 clean, 1 at least one finding, 2 the scan itself failed (an unknown revision, a changed
path whose content is not a readable blob). Each finding prints "path<TAB>rule" and never the
matched text.

Rules: "filename" for a changed path that looks like a credential file (AGENTS.md's .env,
gitea_token, id_rsa and PEM rule, plus other private-key names); the content rules of
conduit_registry.CREDENTIAL_RULES (private-key, provider-token, credential-assignment) over every
line the diff adds. Deleted paths add nothing and are skipped. A rename or copy is scanned under
its new name. Binary content has no lines, so the whole new blob is decoded byte for byte and
scanned. Only names and added lines are judged: a credential already in BASE is not reported.
"""
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from conduit_registry import credential_rules  # noqa: E402

FILENAME = re.compile(r"\.env|gitea_token|id_(?:rsa|dsa|ecdsa|ed25519)|\.pem$|\.key$|\.p12$|\.pfx$",
                      re.IGNORECASE)
BINARY_PROBE = 8000


class ScanFailed(Exception):
    pass


def git(repo: str, *args: str) -> bytes:
    completed = subprocess.run(["git", "-C", repo, "--literal-pathspecs", "-c", "core.quotePath=false", *args],
                               capture_output=True)
    if completed.returncode != 0:
        raise ScanFailed(f"git {args[0]} failed")
    return completed.stdout


def changes(repo: str, base: str, head: str) -> list[tuple[str, str | None, str]]:
    """(status letter, old path or None, new path) for every changed path, renames detected."""
    fields = git(repo, "diff", "--name-status", "-z", "-M", "-C", "--no-ext-diff", base, head).split(b"\0")
    entries = []
    index = 0
    while index < len(fields) and fields[index]:
        status = fields[index].decode()[0]
        if status in "RC":
            old, new = fields[index + 1], fields[index + 2]
            entries.append((status, old.decode("utf-8", "surrogateescape"), new.decode("utf-8", "surrogateescape")))
            index += 3
        else:
            path = fields[index + 1].decode("utf-8", "surrogateescape")
            entries.append((status, None, path))
            index += 2
    return entries


def added_text(repo: str, base: str, head: str, old: str | None, new: str) -> str:
    paths = [old, new] if old else [new]
    diff = git(repo, "diff", "-U0", "-M", "-C", "--no-color", "--no-ext-diff", "--no-textconv", base, head, "--", *paths)
    lines = [line[1:] for line in diff.split(b"\n") if line.startswith(b"+") and not line.startswith(b"+++ ")]
    return b"\n".join(lines).decode("utf-8", "replace")


def scan(repo: str, base: str, head: str) -> list[tuple[str, str]]:
    for revision in (base, head):
        git(repo, "rev-parse", "--verify", "--quiet", f"{revision}^{{commit}}")
    findings: list[tuple[str, str]] = []
    for status, old, path in changes(repo, base, head):
        if status == "D":
            continue
        if FILENAME.search(path):
            findings.append((path, "filename"))
        blob = git(repo, "cat-file", "blob", f"{head}:{path}")
        if b"\0" in blob[:BINARY_PROBE]:
            text = blob.decode("latin-1")
        else:
            text = added_text(repo, base, head, old, path)
        findings += [(path, rule) for rule in credential_rules(text)]
    return sorted(set(findings))


def main() -> int:
    p = argparse.ArgumentParser(description="Scan a diff's changed filenames and added content for credentials.")
    p.add_argument("--base", required=True)
    p.add_argument("--head", required=True)
    p.add_argument("--repo", default=os.getcwd())
    a = p.parse_args()
    try:
        findings = scan(a.repo, a.base, a.head)
    except (ScanFailed, OSError, IndexError, UnicodeDecodeError) as error:
        print(f"scan failed: {error}", file=sys.stderr)
        return 2
    for path, rule in findings:
        print(f"{path}\t{rule}")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
