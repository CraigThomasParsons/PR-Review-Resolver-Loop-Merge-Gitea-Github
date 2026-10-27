#!/usr/bin/env python3
"""agent-labels.py: create the agent pool's agent:* labels on one Gitea repo, idempotently.

The set (the queue states agent:ready, agent:claimed, agent:done, agent:needs-human; the ability
requirements agent:plan, agent:review, agent:prototype, agent:test-author, agent:resolve; and the
agent:promote action, with their colours and descriptions) is the agent:* part of LABELS in
skills/pr-loops-common/gitea-labels.py, so the two never drift. Only those labels are ever created; nothing is edited or deleted. A label that
exists with another colour or description is reported and left as it is.

The existing labels are read through the API, every page, and the script fails closed: if they
cannot all be read, nothing is created. Creates go through `tea labels create`, like
gitea-labels.py, and the labels are read back afterwards to confirm.

Usage:
  agent-labels.py --repo owner/name [--dry-run]

Environment: GITEA_BASE_URL, GITEA_TOKEN (else ~/.config/pulse/gitea_token), TEA_BIN,
TEA_LOGIN, as gitea-labels.py; AGENT_POOL_COMMON (the pr-loops-common directory).

Exit codes: 0 every label present (or, with --dry-run, nothing failed), 1 a create failed or a
label is still missing, 2 bad arguments, 3 the labels could not be read.
"""
import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
import types
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

SCRIPTS = Path(__file__).resolve().parent
COMMON = Path(os.environ.get("AGENT_POOL_COMMON") or SCRIPTS.parent.parent / "skills/pr-loops-common")
REPO_RE = re.compile(r"^(?!\.+/)[A-Za-z0-9_.-]+/(?!\.+$)[A-Za-z0-9_.-]+$")
PAGE = 50
MAX_PAGES = 100


class ReadError(Exception):
    pass


def load_labels_module() -> types.ModuleType:
    spec = importlib.util.spec_from_file_location("gitea_labels", COMMON / "gitea-labels.py")
    if spec is None or spec.loader is None:
        raise SystemExit(f"agent-labels: cannot load {COMMON / 'gitea-labels.py'}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def wanted(mod: types.ModuleType) -> dict[str, tuple[str, str]]:
    return {name: spec for name, spec in mod.LABELS.items() if name.startswith("agent:")}


def existing(mod: types.ModuleType, repo: str) -> dict[str, dict[str, Any]]:
    try:
        token = mod.token()
    except SystemExit as error:
        raise ReadError(str(error)) from None
    found: dict[str, dict[str, Any]] = {}
    for page in range(1, MAX_PAGES + 1):
        query = urllib.parse.urlencode({"limit": PAGE, "page": page})
        url = f"{mod.BASE}/repos/{repo}/labels?{query}"
        req = urllib.request.Request(url, headers={"Authorization": "token " + token})
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                batch = json.load(response)
        except urllib.error.HTTPError as error:
            hint = " (no such repo, or no access to it)" if error.code == 404 else ""
            raise ReadError(f"HTTP {error.code} reading the labels of {repo}{hint}") from None
        except (urllib.error.URLError, OSError, ValueError) as error:
            raise ReadError(f"cannot read the labels of {repo}: {error}") from None
        if not isinstance(batch, list):
            raise ReadError(f"unexpected label listing for {repo}: {str(batch)[:120]}")
        for label in batch:
            if isinstance(label, dict) and isinstance(label.get("name"), str):
                found[label["name"]] = label
        if len(batch) < PAGE:
            return found
    raise ReadError(f"more than {MAX_PAGES} pages of labels on {repo}; refusing to guess")


def create(mod: types.ModuleType, repo: str, name: str, colour: str, desc: str) -> tuple[int, str]:
    try:
        p = subprocess.run(
            [mod.TEA, "labels", "create", "--repo", repo, "--login", mod.LOGIN,
             "--name", name, "--color", "#" + colour, "--description", desc],
            capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as error:
        return 1, str(error)
    return p.returncode, (p.stdout + p.stderr).strip()


def same(label: dict[str, Any], colour: str, desc: str) -> bool:
    return (str(label.get("color", "")).lstrip("#").lower() == colour.lower()
            and (label.get("description") or "") == desc)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", required=True, help="owner/name")
    ap.add_argument("--dry-run", action="store_true", help="say what would be created; create nothing")
    a = ap.parse_args()
    if not REPO_RE.match(a.repo):
        ap.error(f"--repo must be owner/name, got {a.repo!r}")

    mod = load_labels_module()
    labels = wanted(mod)
    try:
        have = existing(mod, a.repo)
    except ReadError as error:
        print(f"agent-labels: {error}; nothing created", file=sys.stderr)
        return 3

    missing = [name for name in labels if name not in have]
    for name, (colour, desc) in labels.items():
        if name in have:
            note = "" if same(have[name], colour, desc) else \
                f" (colour or description differs from #{colour} {desc!r}; left as it is)"
            print(f"  present       {name}{note}")
        elif a.dry_run:
            print(f"  would create  {name}  #{colour}  {desc}")
    if a.dry_run:
        print(f"{a.repo}: {len(missing)} of {len(labels)} agent:* label(s) missing; dry run, nothing created")
        return 0
    if not missing:
        print(f"{a.repo}: all {len(labels)} agent:* labels present")
        return 0

    failed = 0
    for name in missing:
        colour, desc = labels[name]
        rc, out = create(mod, a.repo, name, colour, desc)
        if rc == 0:
            print(f"  created       {name}")
        else:
            failed += 1
            print(f"  FAILED        {name}: {out[:200]}", file=sys.stderr)
    try:
        have = existing(mod, a.repo)
    except ReadError as error:
        print(f"agent-labels: created what it could, but cannot confirm: {error}", file=sys.stderr)
        return 1
    still = [name for name in labels if name not in have]
    if still:
        print(f"agent-labels: {a.repo} is still missing {', '.join(still)}", file=sys.stderr)
        return 1
    print(f"{a.repo}: created {len(missing) - failed}, all {len(labels)} agent:* labels present")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
