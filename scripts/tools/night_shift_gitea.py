#!/usr/bin/env python3
"""night_shift_gitea.py: the two Gitea calls night_shift.sh makes as the controller.

The issue worker never talks to Gitea. The launcher fetches the issue text for the prompt and,
after the worker has committed, opens the pull request. Both calls live here so the token is
read in one place and never reaches argv, stdout or stderr.

Subcommands:
  issue   --repo O/R --issue N --out FILE
          write "Title: ...\\n\\n<body>" to FILE (atomic replace)
  open-pr --repo O/R --head BRANCH --base BASE --title T --body-file F
          print {"number": N, "url": U} for the open PR from BRANCH, creating it when none
          exists, so a rerun after a lost response does not open a second PR

Auth: GITEA_TOKEN, else NIGHT_SHIFT_GITEA_TOKEN_FILE, else ~/.config/pulse/gitea_token.
Base URL: GITEA_BASE_URL (default http://192.168.2.48:3000), as gitea-pr.py.
Exit codes: 0 success, 1 Gitea refused or was unreachable, 2 bad input.
"""
import argparse
import json
import os
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

BASE = os.environ.get("GITEA_BASE_URL", "http://192.168.2.48:3000").rstrip("/") + "/api/v1"
TIMEOUT = 30


def token() -> str:
    """Return the Gitea token without ever printing it."""
    value = os.environ.get("GITEA_TOKEN", "").strip()
    if value:
        return value
    path = Path(os.environ.get("NIGHT_SHIFT_GITEA_TOKEN_FILE", str(Path.home() / ".config/pulse/gitea_token")))
    try:
        value = path.read_text().strip()
    except OSError:
        raise SystemExit("night_shift_gitea: no readable Gitea token")
    if not value:
        raise SystemExit("night_shift_gitea: the Gitea token file is empty")
    return value


def request(method: str, path: str, body: dict | None = None) -> object:
    """One authenticated JSON call; errors name the status, never the token or response."""
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, data=data, method=method,
                                 headers={"Authorization": "token " + token(), "Accept": "application/json"})
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as response:
            return json.loads(response.read().decode() or "null")
    except urllib.error.HTTPError as error:
        print(f"night_shift_gitea: {method} {path.split('?')[0]} -> HTTP {error.code}", file=sys.stderr)
        raise SystemExit(1)
    except (urllib.error.URLError, OSError, ValueError) as error:
        print(f"night_shift_gitea: {method} {path.split('?')[0]} failed: {type(error).__name__}", file=sys.stderr)
        raise SystemExit(1)


def repo_path(repo: str) -> str:
    """Validate owner/name and return its API path."""
    parts = repo.split("/")
    if len(parts) != 2 or not all(parts):
        print("night_shift_gitea: --repo must be owner/name", file=sys.stderr)
        raise SystemExit(2)
    return "/repos/" + "/".join(urllib.parse.quote(part, safe="") for part in parts)


def write_atomic(path: Path, text: str) -> None:
    """Write text so a concurrent reader sees the old file or the whole new one."""
    handle, temporary = tempfile.mkstemp(dir=str(path.parent), prefix=path.name + ".")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as output:
            output.write(text)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    except BaseException:
        if os.path.exists(temporary):
            os.unlink(temporary)
        raise


def cmd_issue(args: argparse.Namespace) -> int:
    """Fetch the issue title and body into --out."""
    issue = request("GET", f"{repo_path(args.repo)}/issues/{args.issue}")
    if not isinstance(issue, dict) or issue.get("pull_request"):
        print("night_shift_gitea: not an issue", file=sys.stderr)
        return 1
    write_atomic(Path(args.out), f"Title: {issue.get('title') or ''}\n\n{issue.get('body') or ''}\n")
    return 0


def cmd_open_pr(args: argparse.Namespace) -> int:
    """Reuse the open PR from --head, else create one; print its number and URL."""
    base_path = repo_path(args.repo)
    pulls = request("GET", f"{base_path}/pulls?state=open&limit=50")
    for pull in pulls if isinstance(pulls, list) else []:
        if isinstance(pull, dict) and (pull.get("head") or {}).get("ref") == args.head:
            print(json.dumps({"number": pull.get("number"), "url": pull.get("html_url")}))
            return 0
    body = Path(args.body_file).read_text(encoding="utf-8")
    created = request("POST", f"{base_path}/pulls",
                      {"head": args.head, "base": args.base, "title": args.title, "body": body})
    if not isinstance(created, dict) or not isinstance(created.get("number"), int):
        print("night_shift_gitea: PR creation returned no number", file=sys.stderr)
        return 1
    print(json.dumps({"number": created["number"], "url": created.get("html_url")}))
    return 0


def main() -> int:
    """Parse the subcommand and run it."""
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    issue = sub.add_parser("issue")
    issue.add_argument("--repo", required=True)
    issue.add_argument("--issue", required=True, type=int)
    issue.add_argument("--out", required=True)
    pr = sub.add_parser("open-pr")
    pr.add_argument("--repo", required=True)
    pr.add_argument("--head", required=True)
    pr.add_argument("--base", required=True)
    pr.add_argument("--title", required=True)
    pr.add_argument("--body-file", required=True)
    args = parser.parse_args()
    if args.command == "issue":
        return cmd_issue(args)
    return cmd_open_pr(args)


if __name__ == "__main__":
    sys.exit(main())
