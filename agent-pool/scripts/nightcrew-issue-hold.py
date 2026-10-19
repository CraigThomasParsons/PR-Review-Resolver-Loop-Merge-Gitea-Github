#!/usr/bin/env python3
"""nightcrew-issue-hold.py --repo owner/name [--timeout SECONDS]

Ask TheNightCrew whether a repo is held by active issue or maintenance work, so
agent-pool-core's claim path can skip a PR claim rather than run a worktree-mutating
job in a repo TheNightCrew's issue workers are touching.

The answer comes from TheNightCrew's own authenticated, read-only endpoint:

    GET {base}/repos/{owner}/{repo}/issue-hold
    Authorization: Bearer <Worker token>
    -> HTTP 200 {"repo": "owner/repo", "held": true|false}

It reports the same predicate ClaimNextJob::blockReason enforces: any non-PR job in
Claimed, Running or Parked on that repo, on ANY worker, not only the caller's. The
Worker behind the token must serve the repo (served_repos), or the answer is 403.

Configuration, matching TheNightCrew's own worker client (scripts/gitea_night):
  AGENT_POOL_NIGHTCREW_URL, else NIGHT_CREW_URL, else http://localhost:8771/api
      the API base, including /api
  AGENT_POOL_NIGHTCREW_TOKEN_FILE, else ~/.config/pulse/night_crew_token
      a file holding the Worker token; there is deliberately no token environment
      variable, since provider CLIs this pool spawns inherit its environment
  AGENT_POOL_NIGHTCREW_TIMEOUT (or --timeout), default 10 seconds

Output and exit status:
  "clear", exit 0   an authenticated HTTP 200 answer for this repo with held=false
  "busy",  exit 0   the same, with held=true
  "busy",  exit 1   anything else: no token, HTTP error, any redirect, timeout,
                    malformed JSON, a repeated JSON key, wrong repo, missing or
                    non-boolean held, a crash
  nothing, exit 2   a usage error
The caller must treat everything except exactly "clear" with exit 0 as held.
Redirects are never followed, so the bearer token only ever goes to the configured
base. The reason for a failure goes to stderr; the token and URL credentials never do.

This is a snapshot, not a mutex: TheNightCrew can claim an issue job the moment after
it answers "clear", and nothing here reserves the repo across the two systems. It
narrows the window ClaimNextJob::blockReason closes inside TheNightCrew; it does not
replace it, and does not prove the two systems converge.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

DEFAULT_BASE = "http://localhost:8771/api"
DEFAULT_TOKEN_FILE = "~/.config/pulse/night_crew_token"
DEFAULT_TIMEOUT = 10.0
MAX_BODY = 64 * 1024
SEGMENT = re.compile(r"[A-Za-z0-9._-]+")


class CheckFailed(Exception):
    """The hold could not be determined; the caller must treat the repo as held."""


class _RefuseRedirects(urllib.request.HTTPRedirectHandler):
    """Turn every 3xx into an HTTPError instead of re-sending the bearer elsewhere."""

    def redirect_request(self, req: urllib.request.Request, fp: object, code: int,
                         msg: str, headers: object, newurl: str) -> None:
        return None


def api_base() -> str:
    base = os.environ.get("AGENT_POOL_NIGHTCREW_URL", "").strip()
    if not base:
        base = os.environ.get("NIGHT_CREW_URL", "").strip() or DEFAULT_BASE
    parts = urllib.parse.urlsplit(base)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise CheckFailed("the NightCrew API base must be an http(s) URL")
    if parts.username is not None or parts.password is not None:
        raise CheckFailed("the NightCrew API base must not carry credentials")
    return base.rstrip("/")


def worker_token() -> str:
    path = Path(os.environ.get("AGENT_POOL_NIGHTCREW_TOKEN_FILE", "").strip()
                or DEFAULT_TOKEN_FILE).expanduser()
    try:
        value = path.read_text(encoding="utf-8").strip()
    except OSError as error:
        raise CheckFailed(f"cannot read the NightCrew Worker token file {path} "
                          f"({error.strerror or type(error).__name__})") from None
    if not value:
        raise CheckFailed(f"the NightCrew Worker token file {path} is empty")
    if any(ch.isspace() or ord(ch) < 0x21 or ord(ch) == 0x7F for ch in value):
        raise CheckFailed(f"the NightCrew Worker token file {path} does not hold one token")
    return value


def checked_repo(repo: str) -> str:
    segments = repo.split("/")
    if len(segments) != 2 or not all(SEGMENT.fullmatch(s) and s not in (".", "..") for s in segments):
        raise CheckFailed("--repo must be owner/name")
    return repo


def _unique_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    """object_pairs_hook: refuse an object that repeats a key, at any depth.

    json.loads keeps the last value of a repeated key and other parsers may keep the first, so
    {"held": true, "held": false} would be read two ways. Such an answer is not valid.
    """
    keys = [key for key, _ in pairs]
    if len(keys) != len(set(keys)):
        raise CheckFailed("response repeats a JSON key")
    return dict(pairs)


def is_held(repo: str, timeout: float) -> bool:
    """Ask the endpoint once; True or False only for a fully valid answer."""
    url = f"{api_base()}/repos/{urllib.parse.quote(repo, safe='/')}/issue-hold"
    request = urllib.request.Request(url, method="GET", headers={
        "Authorization": f"Bearer {worker_token()}", "Accept": "application/json"})
    opener = urllib.request.build_opener(_RefuseRedirects)
    try:
        with opener.open(request, timeout=timeout) as response:
            status = response.status
            body = response.read(MAX_BODY + 1)
    except urllib.error.HTTPError as error:
        hint = {401: " (Worker token rejected)",
                403: " (token is not a Worker serving this repo)"}.get(error.code, "")
        if 300 <= error.code < 400:
            hint = " (redirects are refused)"
        raise CheckFailed(f"HTTP {error.code}{hint}") from None
    except (urllib.error.URLError, OSError) as error:
        reason = getattr(error, "reason", error)
        raise CheckFailed(f"request failed: {type(reason).__name__}") from None
    if status != 200:
        raise CheckFailed(f"HTTP {status}, not 200")
    if len(body) > MAX_BODY:
        raise CheckFailed("response body too large")
    try:
        payload = json.loads(body, object_pairs_hook=_unique_keys)
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise CheckFailed("response is not JSON") from None
    if not isinstance(payload, dict):
        raise CheckFailed("response is not a JSON object")
    if payload.get("repo") != repo:
        raise CheckFailed("response names a different repo")
    held = payload.get("held")
    if not isinstance(held, bool):
        raise CheckFailed("response has no boolean held")
    return held


def seconds(raw: str) -> float:
    try:
        return float(raw)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a number of seconds: {raw!r}") from None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--timeout", type=seconds,
                        default=os.environ.get("AGENT_POOL_NIGHTCREW_TIMEOUT", "").strip() or DEFAULT_TIMEOUT)
    arguments = parser.parse_args()
    try:
        if not 0 < arguments.timeout <= 999:
            raise CheckFailed("--timeout must be more than 0 and at most 999 seconds")
        held = is_held(checked_repo(arguments.repo), arguments.timeout)
    except CheckFailed as error:
        print(f"nightcrew-issue-hold: {error}; failing closed", file=sys.stderr)
        print("busy")
        return 1
    # Anything unforeseen still fails closed, with only the exception type reported.
    except Exception as error:
        print(f"nightcrew-issue-hold: unexpected {type(error).__name__}; failing closed", file=sys.stderr)
        print("busy")
        return 1
    print("busy" if held else "clear")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
