#!/usr/bin/env python3
"""night_shift_gitea.py: the two Gitea calls night_shift.sh makes as the controller.

The issue worker never talks to Gitea. The launcher fetches the issue text for the prompt and,
after the worker has committed, opens the pull request. Both calls live here so the token is
read in one place and never reaches argv, stdout or stderr.

Subcommands:
  issue   --repo O/R --issue N --out FILE
          write "Title: ...\\n\\n<body>" to FILE (atomic replace)
  open-pr --repo O/R --head BRANCH --base BASE --title T --body-file F
          print {"number": N, "url": U} for the open PR from BRANCH of O/R itself (not a
          fork) into BASE (every page of open PRs is searched), creating it when none
          exists, so a rerun after a lost response does not open a second PR; a creation
          answer that is not that PR exits 1

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
PAGE_SIZE = 50
MAX_PAGES = 40


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


def matches(pull: object, repo: str, head: str, base: str) -> bool:
    """True for a numbered PR from this repository's own head branch into base.

    A fork's branch can carry the same name, so both sides' repositories are compared too;
    Gitea treats owner and repository names case-insensitively.
    """
    if not isinstance(pull, dict) or not isinstance(pull.get("number"), int):
        return False
    sides = [pull.get("head"), pull.get("base")]
    if not all(isinstance(side, dict) for side in sides):
        return False
    names = [side.get("repo").get("full_name") if isinstance(side.get("repo"), dict) else None for side in sides]
    return sides[0].get("ref") == head and sides[1].get("ref") == base \
        and all(isinstance(name, str) and name.casefold() == repo.casefold() for name in names)


def cmd_open_pr(args: argparse.Namespace) -> int:
    """Reuse the open PR from --head into --base, else create one; print its number and URL."""
    base_path = repo_path(args.repo)
    for page in range(1, MAX_PAGES + 1):
        pulls = request("GET", f"{base_path}/pulls?state=open&limit={PAGE_SIZE}&page={page}")
        if not isinstance(pulls, list) or not pulls:
            break
        for pull in pulls:
            if matches(pull, args.repo, args.head, args.base):
                print(json.dumps({"number": pull["number"], "url": pull.get("html_url")}))
                return 0
    else:
        print("night_shift_gitea: too many open PRs to search for an existing one", file=sys.stderr)
        return 1
    body = Path(args.body_file).read_text(encoding="utf-8")
    created = request("POST", f"{base_path}/pulls",
                      {"head": args.head, "base": args.base, "title": args.title, "body": body})
    # The caller writes a success receipt from this answer, so it must be the PR just asked for.
    if not matches(created, args.repo, args.head, args.base):
        print("night_shift_gitea: PR creation did not return a PR from the head branch into the base",
              file=sys.stderr)
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
