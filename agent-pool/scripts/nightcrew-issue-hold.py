#!/usr/bin/env python3
"""nightcrew-issue-hold.py --repo owner/name --bot login

Check whether TheNightCrew's issue-kind worker currently holds any open issue in
this repo, so agent-pool-core's claim path can skip a PR claim rather than run a
worktree-mutating job in a repo an issue worker is actively touching. There is no
database shared between the two systems; the one durable, always-set signal is
the Gitea side-effect TheNightCrew's own GiteaFence.markClaimed() already performs
on every claim: it assigns the crew bot to the issue (always) and optionally also
applies a "status: in-progress" label (off by default) -- so the bot-assignee
check is the one that cannot silently be absent even with the label feature off.

Prints "busy" or "clear" and always exits 0, except on a usage error (exit 2). On
any read failure, uncertainty resolves to "busy": this check runs every tick, so a
transient failure only costs one skipped tick, and that is cheaper than the thing
it exists to prevent.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

BASE = os.environ.get("GITEA_BASE_URL", "http://192.168.2.48:3000").rstrip("/") + "/api/v1"


def token() -> str:
    tok = os.environ.get("GITEA_TOKEN", "").strip()
    if tok:
        return tok
    path = Path.home() / ".config/pulse/gitea_token"
    if path.exists():
        return path.read_text().strip()
    raise SystemExit("nightcrew-issue-hold: no token in GITEA_TOKEN or ~/.config/pulse/gitea_token")


def open_issues(repo: str) -> list[dict]:
    """Every open, non-PR issue in repo, paginated."""
    found: list[dict] = []
    page = 1
    while True:
        query = urllib.parse.urlencode(
            {"state": "open", "type": "issues", "page": page, "limit": 50}
        )
        request = urllib.request.Request(
            f"{BASE}/repos/{repo}/issues?{query}",
            headers={"Authorization": f"token {token()}", "Accept": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=15) as response:
            batch = json.loads(response.read())
        found.extend(batch)
        if len(batch) < 50:
            return found
        page += 1


def held_by(repo: str, bot: str) -> bool:
    for issue in open_issues(repo):
        assignees = [a["login"] for a in (issue.get("assignees") or [])]
        if bot in assignees:
            return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--bot", required=True)
    arguments = parser.parse_args()
    try:
        busy = held_by(arguments.repo, arguments.bot)
    # Anything held_by() can raise reads as busy, including token()'s SystemExit and the
    # AttributeError/TypeError of an unexpected payload shape (an error object, not a list).
    except (Exception, SystemExit):
        busy = True
    print("busy" if busy else "clear")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
