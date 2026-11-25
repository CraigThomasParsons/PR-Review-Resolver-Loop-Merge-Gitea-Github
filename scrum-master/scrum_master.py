#!/usr/bin/env python3
"""scrum_master.py: the Hermes Scrum Master, a local Needs-Human fallback.

When Grok Bot is rate limited, items that need Craig just sit there. This tick finds them and
asks Craig about each one in a Slack DM, then relays his exact answer to Gitea for whoever acts
on it. It never acts on an answer itself, and it never invokes an LLM: like the doctor, it must
not itself be rate-limitable.

One tick (run by hermes-scrum-master.timer, or by hand):
  1. Watch (read-only):
       - open Gitea PRs labelled agent:needs-human or review:needs-human
       - NightCrew jobs that failed, were flagged needs-human, or hold a lease nobody renews,
         read straight from NightCrew's SQLite file opened with mode=ro and query_only.
         NightCrew's HTTP API is never called (its read routes are scoped to one worker's
         jobs, and the write routes, POST /claim-next above all, are off limits).
  2. Ask: one Slack DM per item: the decision first, then lettered options, then the
     Tailscale link. An item is asked about once per fingerprint (PR head + needs-human
     labels; job status + attempt + failure streak); it is re-asked only when that changes.
  3. Relay: Craig's reply in the question's thread, taken only from his Slack user id and
     only from a human message (no bot_id, no subtype), is posted word for word as a Gitea
     comment on the PR or issue, addressed to whoever acts on it. The comment carries a
     hidden marker, so a crash between posting and saving state never posts it twice.
  4. Hand-back: every question and relay is appended to qa-log.jsonl in the state dir;
     `scrum_master.py log` prints it for Projects Manager and Scrum Master.

The only Gitea write it can make is POST /repos/{owner}/{repo}/issues/{n}/comments; the
client refuses every other write, so it cannot merge, push, relabel or close anything.

Usage:
  scrum_master.py tick [--dry-run] [--config FILE]   one pass (the default command)
  scrum_master.py log  [--config FILE] [--since ISO]  print the Q&A log as JSON lines
  scrum_master.py check [--config FILE]               validate config and credentials files

Exit status: 0 ok, 1 the tick finished with errors (see stderr / the report), 2 unusable setup.

Environment:
  HSM_CONFIG        config file (default ~/.config/hermes-scrum-master/config.toml)
  HSM_STATE         state dir (default ~/.local/state/hermes-scrum-master)
  HSM_DRY_RUN=1     same as --dry-run
  GITEA_TOKEN       Gitea token, else [gitea].token_file (default ~/.config/pulse/gitea_token)
  SLACK_BOT_TOKEN   Slack bot token (xoxb-...), else [slack].token_file
  HSM_SLACK_API     Slack API base (default https://slack.com/api), for tests
  HSM_NOW           pin the clock (Unix seconds), for tests
Tokens are only ever sent as request headers, never logged or written to state.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html
import json
import os
import re
import sqlite3
import sys
import tempfile
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

MARKER = "hermes-scrum-master:relay"
NEEDS_HUMAN_LABELS = ("agent:needs-human", "review:needs-human")
LIVE_STATUSES = ("claimed", "running", "parked")
DEFAULTS: dict[str, Any] = {
    "gitea": {
        "api_base": "http://192.168.2.48:3000",
        "public_base": "http://ubuntu-2404.tail99f840.ts.net:3000",
        "token_file": "~/.config/pulse/gitea_token",
        "labels": list(NEEDS_HUMAN_LABELS),
        "repos": [],
    },
    "nightcrew": {
        "enabled": True,
        "db_path": "~/Code/TheNightCrew/database/database.sqlite",
        "stuck_after_minutes": 90,
        "ignore_failed_before": "",
        "repos": [],
    },
    "slack": {
        "token_file": "~/.config/hermes-scrum-master/slack_bot_token",
        "craig_user_id": "",
    },
    "ask": {
        "max_new_per_tick": 5,
        "answer_window_days": 14,
    },
    "relay": {
        "mentions": {},
        "nightcrew_mention": "",
    },
}


class SetupError(Exception):
    """The config or a credential is unusable; nothing was decided."""


class RefusedWrite(Exception):
    """A write outside the one allowed shape was attempted."""


# --------------------------------------------------------------------------- time and files

def now() -> float:
    pinned = os.environ.get("HSM_NOW", "").strip()
    return float(pinned) if pinned else time.time()


def iso(ts: float) -> str:
    return dt.datetime.fromtimestamp(ts, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def et_label(ts: float) -> str:
    """Craig reads times in Toronto time."""
    try:
        from zoneinfo import ZoneInfo
        local = dt.datetime.fromtimestamp(ts, ZoneInfo("America/Toronto"))
        return local.strftime("%Y-%m-%d %-I:%M %p ET")
    except Exception:  # zoneinfo data missing: fall back to UTC, labelled as such
        return iso(ts).replace("T", " ").replace("Z", " UTC")


def parse_db_time(value: str | None) -> float | None:
    """NightCrew stores 'YYYY-MM-DD HH:MM:SS' in UTC."""
    if not value:
        return None
    text = value.strip().replace("T", " ").rstrip("Z")
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d"):
        try:
            return dt.datetime.strptime(text, fmt).replace(tzinfo=dt.timezone.utc).timestamp()
        except ValueError:
            continue
    return None


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise
    dir_fd = os.open(str(path.parent), os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)


def append_line(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    line = json.dumps(record, sort_keys=True) + "\n"
    fd = os.open(str(path), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(fd, line.encode())
        os.fsync(fd)
    finally:
        os.close(fd)


def expand(path: str) -> Path:
    return Path(os.path.expandvars(os.path.expanduser(path)))


# --------------------------------------------------------------------------- config

def merge(base: dict[str, Any], over: dict[str, Any]) -> dict[str, Any]:
    out = dict(base)
    for key, value in over.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = merge(out[key], value)
        else:
            out[key] = value
    return out


def config_path(arg: str | None) -> Path:
    return expand(arg or os.environ.get("HSM_CONFIG") or "~/.config/hermes-scrum-master/config.toml")


def load_config(arg: str | None) -> dict[str, Any]:
    path = config_path(arg)
    try:
        raw = tomllib.loads(path.read_text())
    except FileNotFoundError:
        raise SetupError(f"no config at {path} (copy scrum-master/config/config.example.toml)")
    except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError) as error:
        raise SetupError(f"unreadable config {path}: {error}")
    cfg = merge(DEFAULTS, raw)
    craig = str(cfg["slack"].get("craig_user_id", "")).strip()
    if not re.fullmatch(r"[UW][A-Z0-9]{6,}", craig):
        raise SetupError("[slack].craig_user_id must be Craig's Slack user id (U...)")
    labels = cfg["gitea"]["labels"]
    if not labels or not all(isinstance(l, str) and l for l in labels):
        raise SetupError("[gitea].labels must be a non-empty list of label names")
    for key in ("api_base", "public_base"):
        if not str(cfg["gitea"][key]).startswith(("http://", "https://")):
            raise SetupError(f"[gitea].{key} must be an http(s) URL")
    cfg["_path"] = str(path)
    return cfg


def read_secret(env_name: str, file_setting: str, what: str) -> str:
    value = os.environ.get(env_name, "").strip()
    if value:
        return value
    path = expand(file_setting)
    try:
        value = path.read_text().strip()
    except OSError:
        raise SetupError(f"no {what}: set {env_name} or put it in {path}")
    if not value:
        raise SetupError(f"no {what}: {path} is empty")
    return value


def state_dir() -> Path:
    path = expand(os.environ.get("HSM_STATE") or "~/.local/state/hermes-scrum-master")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    return path


# --------------------------------------------------------------------------- HTTP

def http_json(method: str, url: str, headers: dict[str, str], body: Any = None,
              form: dict[str, str] | None = None, timeout: float = 30) -> Any:
    data = None
    headers = dict(headers)
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json; charset=utf-8"
    elif form is not None:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"HTTP {error.code} on {method} {urllib.parse.urlsplit(url).path}")
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise RuntimeError(f"{method} {urllib.parse.urlsplit(url).path}: {error}")
    return json.loads(raw) if raw else None


COMMENT_PATH = re.compile(r"^/repos/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/issues/[0-9]+/comments$")


class Gitea:
    """Reads anything; writes only an issue/PR comment. Nothing else can be sent."""

    def __init__(self, api_base: str, public_base: str, token: str) -> None:
        self.api = api_base.rstrip("/") + "/api/v1"
        self.lan = api_base.rstrip("/")
        self.public = public_base.rstrip("/")
        self.headers = {"Authorization": "token " + token, "Accept": "application/json"}

    def get(self, path: str, query: dict[str, Any] | None = None) -> Any:
        url = self.api + path + ("?" + urllib.parse.urlencode(query) if query else "")
        return http_json("GET", url, self.headers)

    def post_comment(self, repo: str, number: int, body: str) -> Any:
        path = f"/repos/{repo}/issues/{int(number)}/comments"
        if not COMMENT_PATH.match(path):
            raise RefusedWrite(f"refusing write to {path}")
        return http_json("POST", self.api + path, self.headers, body={"body": body})

    def tailscale(self, url: str) -> str:
        """Craig opens links over Tailscale, never the LAN address."""
        if url.startswith(self.lan):
            return self.public + url[len(self.lan):]
        parts = urllib.parse.urlsplit(url)
        return self.public + parts.path + (("?" + parts.query) if parts.query else "")

    def pull_url(self, repo: str, number: int) -> str:
        return f"{self.public}/{repo}/pulls/{number}"

    def issue_url(self, repo: str, number: int) -> str:
        return f"{self.public}/{repo}/issues/{number}"

    def needs_human_prs(self, labels: list[str], repos: list[str]) -> list[dict[str, Any]]:
        found: dict[tuple[str, int], dict[str, Any]] = {}
        for label in labels:
            page = 1
            while True:
                query: dict[str, Any] = {"type": "pulls", "state": "open", "labels": label,
                                         "limit": 50, "page": page}
                batch = self.get("/repos/issues/search", query)
                if not isinstance(batch, list):
                    raise RuntimeError("Gitea issue search did not return a list")
                for issue in batch:
                    repo = ((issue.get("repository") or {}).get("full_name") or "")
                    if not repo or (repos and repo not in repos):
                        continue
                    found[(repo, int(issue["number"]))] = issue
                if len(batch) < 50:
                    break
                page += 1
                if page > 100:
                    raise RuntimeError("Gitea issue search paginated past 100 pages")
        out = []
        for (repo, number), issue in sorted(found.items()):
            pull = self.get(f"/repos/{repo}/pulls/{number}")
            pr_labels = sorted(l.get("name", "") for l in (pull.get("labels") or []))
            out.append({
                "repo": repo,
                "number": number,
                "title": pull.get("title") or issue.get("title") or "",
                "head_sha": ((pull.get("head") or {}).get("sha") or ""),
                "base_ref": ((pull.get("base") or {}).get("ref") or ""),
                "author": ((pull.get("user") or {}).get("login") or ""),
                "labels": pr_labels,
                "state": pull.get("state") or "open",
            })
        return out

    def comments(self, repo: str, number: int) -> list[dict[str, Any]]:
        rows, page = [], 1
        while True:
            batch = self.get(f"/repos/{repo}/issues/{number}/comments", {"limit": 50, "page": page})
            if not isinstance(batch, list):
                return rows
            rows.extend(batch)
            if len(batch) < 50 or page > 40:
                return rows
            page += 1


class Slack:
    def __init__(self, token: str, base: str | None = None) -> None:
        self.base = (base or os.environ.get("HSM_SLACK_API") or "https://slack.com/api").rstrip("/")
        self.headers = {"Authorization": "Bearer " + token}

    def call(self, method: str, **params: str) -> dict[str, Any]:
        result = http_json("POST", f"{self.base}/{method}", self.headers, form=params)
        if not isinstance(result, dict) or not result.get("ok"):
            error = result.get("error") if isinstance(result, dict) else "bad response"
            raise RuntimeError(f"Slack {method}: {error}")
        return result

    def dm_channel(self, user_id: str) -> str:
        return str(self.call("conversations.open", users=user_id)["channel"]["id"])

    def post(self, channel: str, text: str) -> str:
        result = self.call("chat.postMessage", channel=channel, text=text,
                           unfurl_links="false", unfurl_media="false")
        return str(result["ts"])

    def replies(self, channel: str, ts: str) -> list[dict[str, Any]]:
        return list(self.call("conversations.replies", channel=channel, ts=ts,
                              limit="100").get("messages") or [])


# --------------------------------------------------------------------------- NightCrew (read-only)

def open_nightcrew(db_path: Path) -> sqlite3.Connection:
    """mode=ro refuses writes at the SQLite layer; query_only refuses them again."""
    if not db_path.exists():
        raise RuntimeError(f"NightCrew DB not found at {db_path}")
    uri = "file:" + urllib.parse.quote(str(db_path)) + "?mode=ro"
    conn = sqlite3.connect(uri, uri=True, timeout=10)
    conn.execute("PRAGMA query_only = ON")
    conn.row_factory = sqlite3.Row
    return conn


JOB_COLUMNS = ("id", "repo", "kind", "reference", "status", "attempt", "consecutive_failures",
               "last_failure_reason", "last_failed_at", "needs_human_at", "lease_expires_at",
               "last_heartbeat_at", "claimed_at", "claimed_by", "worker_id", "parked_reason",
               "resets_at", "payload", "updated_at")


def nightcrew_items(cfg: dict[str, Any], at: float, watch_since: float | None = None) -> list[dict[str, Any]]:
    nc = cfg["nightcrew"]
    conn = open_nightcrew(expand(nc["db_path"]))
    try:
        cols = {row[1] for row in conn.execute("PRAGMA table_info(night_crew_jobs)")}
        wanted = [c for c in JOB_COLUMNS if c in cols]
        placeholders = ",".join("?" for _ in LIVE_STATUSES)
        rows = conn.execute(
            f"SELECT {', '.join(wanted)} FROM night_crew_jobs "
            f"WHERE status = 'failed' OR needs_human_at IS NOT NULL OR status IN ({placeholders}) "
            "ORDER BY id DESC", LIVE_STATUSES).fetchall()
    finally:
        conn.close()
    stuck_after = float(nc["stuck_after_minutes"]) * 60
    # An explicit ignore_failed_before wins; otherwise failures from before the first real tick
    # (the day the service was enabled) are the backlog, and are not asked about.
    cutoff = parse_db_time(nc.get("ignore_failed_before") or "") or watch_since
    repos = nc.get("repos") or []
    out = []
    for row in rows:
        job = {k: row[k] for k in row.keys()}
        if repos and job.get("repo") not in repos:
            continue
        status = job.get("status")
        reason = ""
        if status == "failed":
            failed_at = parse_db_time(job.get("last_failed_at")) or parse_db_time(job.get("updated_at"))
            if cutoff and failed_at and failed_at < cutoff:
                continue
            reason = "failed"
        elif job.get("needs_human_at"):
            reason = "needs-human"
        elif status in LIVE_STATUSES:
            lease = parse_db_time(job.get("lease_expires_at"))
            beat = parse_db_time(job.get("last_heartbeat_at")) or parse_db_time(job.get("claimed_at"))
            if status == "parked":
                resets = parse_db_time(job.get("resets_at"))
                if resets and resets > at:
                    continue  # parked on a rate limit that has not reset yet: expected
            if lease is not None and lease < at:
                reason = "stuck"
            elif beat is not None and at - beat > stuck_after:
                reason = "stuck"
        if not reason:
            continue
        try:
            payload = json.loads(job.get("payload") or "{}")
        except (TypeError, ValueError):
            payload = {}
        job["payload"] = payload if isinstance(payload, dict) else {}
        job["reason"] = reason
        out.append(job)
    return out


# --------------------------------------------------------------------------- items and questions

@dataclass
class Item:
    key: str
    fingerprint: str
    decision: str
    options: list[str]
    link: str
    target_repo: str | None
    target_number: int | None
    mention: str
    summary: dict[str, Any] = field(default_factory=dict)


def fingerprint(*parts: Any) -> str:
    return hashlib.sha256(json.dumps(parts, sort_keys=True, default=str).encode()).hexdigest()[:16]


def pr_item(pr: dict[str, Any], gitea: Gitea, cfg: dict[str, Any]) -> Item:
    watched = [l for l in pr["labels"] if l in cfg["gitea"]["labels"]]
    label = watched[0] if watched else cfg["gitea"]["labels"][0]
    mentions = cfg["relay"].get("mentions") or {}
    mention = mentions.get(label) or (f"@{pr['author']}" if pr["author"] else "")
    title = pr["title"].strip() or "(no title)"
    where = f"{pr['repo']} PR #{pr['number']} \"{title}\""
    if label == "agent:needs-human":
        decision = (f"{where} is labelled agent:needs-human: the agent pool could not place it. "
                    "What should happen to it?")
        options = ["Requeue it for the agent pool (back to agent:ready).",
                   "Give it to one provider or bot I name in my reply.",
                   "Hold it; I will look at it myself.",
                   "Close it without merging."]
    else:
        decision = (f"{where} is labelled review:needs-human: the review/resolve loop wants "
                    "your judgement. What should happen next?")
        options = ["Send it back for another review/resolve pass (review:requested).",
                   "It is fine as is; it may go to the merge loop.",
                   "Hold it; I will look at it myself.",
                   "Close it without merging."]
    short = pr["head_sha"][:8] or "unknown"
    return Item(
        key=f"pr:{pr['repo']}#{pr['number']}",
        fingerprint=fingerprint("pr", pr["head_sha"], watched, pr["state"]),
        decision=decision, options=options, link=gitea.pull_url(pr["repo"], pr["number"]),
        target_repo=pr["repo"], target_number=pr["number"], mention=mention,
        summary={"kind": "pr", "repo": pr["repo"], "number": pr["number"], "head": short,
                 "labels": watched, "base": pr["base_ref"]})


def job_target(job: dict[str, Any]) -> int | None:
    match = re.fullmatch(r"#?([0-9]+)", str(job.get("reference") or "").strip())
    return int(match.group(1)) if match else None


def job_item(job: dict[str, Any], gitea: Gitea, cfg: dict[str, Any]) -> Item:
    repo = str(job.get("repo") or "")
    number = job_target(job)
    kind = str(job.get("kind") or "job")
    title = str(job["payload"].get("title") or "").strip()
    noun = {"pull_request": "PR", "issue": "issue"}.get(kind, kind)
    ref = f" {job['reference']}" if job.get("reference") else ""
    what = f"NightCrew job {job['id']} ({noun}{ref} in {repo}" + (f", \"{title}\")" if title else ")")
    drop = "Drop it (close the issue)." if number is not None else "Drop the job."
    attempts = job.get("attempt") or 0
    streak = job.get("consecutive_failures") or 0
    if job["reason"] == "failed":
        why = str(job.get("last_failure_reason") or "no reason recorded")[:160]
        decision = (f"{what} failed ({why}) after {attempts} attempt(s), {streak} in a row. "
                    "What should happen to it?")
        options = ["Requeue it as is.", "Requeue it with the change I describe in my reply.",
                   "Leave it failed; I will look at it myself.", drop]
        fp = fingerprint("nc", "failed", job.get("status"), attempts, streak,
                         job.get("last_failed_at"), job.get("last_failure_reason"))
    elif job["reason"] == "needs-human":
        decision = (f"{what} was flagged needs-human at {job.get('needs_human_at')} UTC "
                    f"(status {job.get('status')}, {streak} failure(s) in a row). What next?")
        options = ["Requeue it as is.", "Requeue it with the change I describe in my reply.",
                   "Leave it parked; I will look at it myself.", drop]
        fp = fingerprint("nc", "needs-human", job.get("status"), attempts, job.get("needs_human_at"))
    else:
        seen = job.get("last_heartbeat_at") or job.get("claimed_at") or "never"
        decision = (f"{what} looks stuck: status {job.get('status')}, claimed by "
                    f"{job.get('claimed_by') or job.get('worker_id') or 'unknown'}, last heartbeat "
                    f"{seen} UTC, lease until {job.get('lease_expires_at') or 'none'} UTC. What next?")
        options = ["Release it back to the queue.", "Leave it; the worker is still alive.",
                   "Mark it failed; I will look at it myself."]
        fp = fingerprint("nc", "stuck", job.get("status"), attempts, job.get("claimed_at"))
    url = str(job["payload"].get("url") or "")
    if url:
        link = gitea.tailscale(url)
    elif repo and number is not None:
        link = gitea.pull_url(repo, number) if kind == "pull_request" else gitea.issue_url(repo, number)
    else:
        link = f"{gitea.public}/{repo}" if repo else gitea.public
    return Item(
        key=f"nc:{job['id']}", fingerprint=fp, decision=decision, options=options, link=link,
        target_repo=repo if (repo and number is not None) else None, target_number=number,
        mention=cfg["relay"].get("nightcrew_mention") or "",
        summary={"kind": "nightcrew", "job": job["id"], "repo": repo, "reason": job["reason"],
                 "status": job.get("status"), "attempt": attempts})


def letters(n: int) -> list[str]:
    return [chr(ord("a") + i) for i in range(n)]


def question_text(item: Item) -> str:
    lines = [f"*Decision needed:* {item.decision}", ""]
    for letter, option in zip(letters(len(item.options) + 1), item.options + [
            "Something else: reply in your own words."]):
        lines.append(f"{letter}) {option}")
    where = ("get posted to Gitea for whoever acts on it" if item.target_repo
             else "go to the hand-back log only (there is no Gitea issue or PR to post them on)")
    lines += ["", item.link, "",
              f"_Reply in this thread. Your exact words {where}; I take no action myself. "
              f"Ref {item.key} @ {item.fingerprint}_"]
    return "\n".join(lines)


def slack_unescape(text: str) -> str:
    """Slack escapes only &, < and >; undoing that gives back exactly what Craig typed."""
    return html.unescape(text.replace("&amp;", "\x00")).replace("\x00", "&") if text else ""


def relay_body(item: dict[str, Any], answer: str, answered_at: float) -> str:
    quoted = "\n".join("> " + line if line else ">" for line in answer.splitlines()) or ">"
    head = f"{item['mention']} " if item.get("mention") else ""
    options = "\n".join(f"{letter}) {opt}" for letter, opt in
                        zip(letters(len(item["options"]) + 1),
                            item["options"] + ["Something else (own words)."]))
    return "\n".join([
        f"<!-- {MARKER} key={item['key']} fp={item['fingerprint']} slack_ts={item['answer_ts']} -->",
        "**Relayed by Hermes Scrum Master** from Craig's Slack DM. The bot posts this under "
        "this Gitea account; only the quoted words below are Craig's.",
        "",
        f"{head}Craig answered in his Slack DM at {et_label(answered_at)}, word for word:",
        "",
        quoted,
        "",
        f"The question was: {item['decision']}",
        "",
        options,
        "",
        "_The relay itself has taken no action._",
    ])


def craig_answer(messages: list[dict[str, Any]], question_ts: str,
                 craig: str) -> dict[str, Any] | None:
    """The first human reply from Craig's own user id after the question; nothing else counts."""
    best = None
    for msg in messages:
        ts = str(msg.get("ts") or "")
        if not ts or ts == question_ts or float(ts) <= float(question_ts):
            continue
        if msg.get("user") != craig or msg.get("bot_id") or msg.get("subtype"):
            continue
        if not str(msg.get("text") or "").strip():
            continue
        if best is None or float(ts) < float(best["ts"]):
            best = msg
    return best


# --------------------------------------------------------------------------- the tick

class Tick:
    def __init__(self, cfg: dict[str, Any], gitea: Gitea, slack: Slack | None, dry: bool) -> None:
        self.cfg, self.gitea, self.slack, self.dry = cfg, gitea, slack, dry
        self.dir = state_dir()
        self.state_path = self.dir / "state.json"
        self.log_path = self.dir / "qa-log.jsonl"
        self.at = now()
        self.errors: list[str] = []
        self.report: dict[str, list[Any]] = {"asked": [], "unchanged": [], "relayed": [],
                                             "resolved": [], "deferred": [], "skipped": []}
        try:
            self.state = json.loads(self.state_path.read_text())
        except FileNotFoundError:
            self.state = {"version": 1, "items": {}, "questions": []}
        except (OSError, ValueError) as error:
            raise SetupError(f"unreadable state {self.state_path}: {error}")

    def log(self, event: str, **fields: Any) -> None:
        record = {"at": iso(self.at), "event": event, **fields}
        if self.dry:
            print("dry-run: " + json.dumps(record, sort_keys=True), file=sys.stderr)
        else:
            append_line(self.log_path, record)

    def save(self) -> None:
        if not self.dry:
            atomic_write(self.state_path, json.dumps(self.state, indent=2, sort_keys=True) + "\n")

    def collect(self) -> list[Item]:
        items: list[Item] = []
        try:
            for pr in self.gitea.needs_human_prs(self.cfg["gitea"]["labels"],
                                                 self.cfg["gitea"].get("repos") or []):
                items.append(pr_item(pr, self.gitea, self.cfg))
        except RuntimeError as error:
            self.errors.append(f"gitea: {error}")
        if self.cfg["nightcrew"].get("enabled", True):
            try:
                since = self.state.setdefault("watch_since", iso(self.at))
                watch_since = dt.datetime.strptime(since, "%Y-%m-%dT%H:%M:%SZ").replace(
                    tzinfo=dt.timezone.utc).timestamp()
                for job in nightcrew_items(self.cfg, self.at, watch_since):
                    items.append(job_item(job, self.gitea, self.cfg))
            except (RuntimeError, sqlite3.Error) as error:
                self.errors.append(f"nightcrew: {error}")
        return items

    def dm(self) -> str:
        channel = self.state.get("dm_channel")
        if not channel:
            assert self.slack is not None
            channel = self.slack.dm_channel(self.cfg["slack"]["craig_user_id"])
            self.state["dm_channel"] = channel
        return str(channel)

    def ask(self, items: list[Item]) -> None:
        known: dict[str, Any] = self.state.setdefault("items", {})
        budget = int(self.cfg["ask"]["max_new_per_tick"])
        live = {item.key for item in items}
        for key, entry in known.items():
            if key not in live and not entry.get("resolved_at"):
                entry["resolved_at"] = iso(self.at)
                self.report["resolved"].append(key)
                self.log("resolved", key=key, fingerprint=entry.get("fingerprint"))
        for item in items:
            entry = known.get(item.key)
            if entry and entry.get("fingerprint") == item.fingerprint and not entry.get("resolved_at"):
                self.report["unchanged"].append(item.key)
                continue
            if budget <= 0:
                self.report["deferred"].append(item.key)
                continue
            text = question_text(item)
            if self.dry or self.slack is None:
                print(f"dry-run: would DM Craig:\n{text}\n", file=sys.stderr)
                self.report["asked"].append({"key": item.key, "fingerprint": item.fingerprint})
                budget -= 1
                continue
            try:
                channel = self.dm()
                ts = self.slack.post(channel, text)
            except RuntimeError as error:
                self.errors.append(f"slack ask {item.key}: {error}")
                continue
            budget -= 1
            for q in self.state.setdefault("questions", []):
                if q["key"] == item.key and not q.get("relayed_at") and not q.get("superseded_by"):
                    q["superseded_by"] = ts
            question = {"key": item.key, "fingerprint": item.fingerprint, "channel": channel,
                        "ts": ts, "asked_at": iso(self.at), "decision": item.decision,
                        "options": item.options, "link": item.link, "mention": item.mention,
                        "target_repo": item.target_repo, "target_number": item.target_number}
            self.state["questions"].append(question)
            known[item.key] = {"fingerprint": item.fingerprint, "asked_at": iso(self.at),
                               "question_ts": ts, "summary": item.summary}
            self.report["asked"].append({"key": item.key, "fingerprint": item.fingerprint, "ts": ts})
            self.log("asked", key=item.key, fingerprint=item.fingerprint, slack_ts=ts,
                     decision=item.decision, options=item.options, link=item.link)
            self.save()  # one question per save: a crash never forgets a question it sent

    def already_relayed(self, q: dict[str, Any]) -> bool:
        needle = f"{MARKER} key={q['key']} fp={q['fingerprint']} slack_ts={q['answer_ts']}"
        return any(needle in str(c.get("body") or "")
                   for c in self.gitea.comments(q["target_repo"], int(q["target_number"])))

    def relay(self) -> None:
        if self.slack is None:
            return
        craig = self.cfg["slack"]["craig_user_id"]
        window = float(self.cfg["ask"]["answer_window_days"]) * 86400
        for q in self.state.get("questions", []):
            if q.get("relayed_at") or q.get("unrelayable_at"):
                continue
            asked = dt.datetime.strptime(q["asked_at"], "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=dt.timezone.utc).timestamp()
            if self.at - asked > window:
                continue
            try:
                answer = craig_answer(self.slack.replies(q["channel"], q["ts"]), q["ts"], craig)
            except RuntimeError as error:
                self.errors.append(f"slack replies {q['key']}: {error}")
                continue
            if answer is None:
                continue
            words = slack_unescape(str(answer["text"]))
            q["answer_ts"] = str(answer["ts"])
            q["answer"] = words
            if not q.get("target_repo") or q.get("target_number") is None:
                q["unrelayable_at"] = iso(self.at)
                self.log("answer-unrelayable", key=q["key"], fingerprint=q["fingerprint"],
                         slack_ts=q["answer_ts"], answer=words,
                         why="no Gitea issue or PR to comment on")
                self.save()
                continue
            if self.dry:
                print(f"dry-run: would relay to {q['target_repo']}#{q['target_number']}: {words!r}",
                      file=sys.stderr)
                continue
            try:
                if not self.already_relayed(q):
                    body = relay_body(q, words, float(answer["ts"]))
                    self.gitea.post_comment(q["target_repo"], int(q["target_number"]), body)
            except RuntimeError as error:
                self.errors.append(f"gitea relay {q['key']}: {error}")
                continue
            q["relayed_at"] = iso(self.at)
            self.report["relayed"].append({"key": q["key"], "slack_ts": q["answer_ts"]})
            self.log("relayed", key=q["key"], fingerprint=q["fingerprint"],
                     slack_ts=q["answer_ts"], answer=words,
                     target=f"{q['target_repo']}#{q['target_number']}",
                     superseded=bool(q.get("superseded_by")))
            self.save()

    def run(self) -> dict[str, Any]:
        self.relay()  # answers first, so a reply is relayed before its item is re-asked
        self.ask(self.collect())
        self.save()
        return {"version": 1, "at": iso(self.at), "dry_run": self.dry, **self.report,
                "errors": self.errors}


# --------------------------------------------------------------------------- entry points

def build(cfg: dict[str, Any], dry: bool) -> tuple[Gitea, Slack | None]:
    gitea_token = read_secret("GITEA_TOKEN", cfg["gitea"]["token_file"], "Gitea token")
    gitea = Gitea(cfg["gitea"]["api_base"], cfg["gitea"]["public_base"], gitea_token)
    slack = None
    try:
        slack = Slack(read_secret("SLACK_BOT_TOKEN", cfg["slack"]["token_file"], "Slack bot token"))
    except SetupError:
        if not dry:
            raise
    return gitea, slack


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("command", nargs="?", default="tick", choices=["tick", "log", "check"])
    parser.add_argument("--config")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--since", help="log: only records at or after this ISO time")
    args = parser.parse_args(argv)
    dry = args.dry_run or os.environ.get("HSM_DRY_RUN") == "1"
    try:
        cfg = load_config(args.config)
        if args.command == "log":
            path = state_dir() / "qa-log.jsonl"
            if path.exists():
                for line in path.read_text().splitlines():
                    if not args.since or json.loads(line).get("at", "") >= args.since:
                        print(line)
            return 0
        gitea, slack = build(cfg, dry)
        if args.command == "check":
            if cfg["nightcrew"].get("enabled", True):
                open_nightcrew(expand(cfg["nightcrew"]["db_path"])).close()
            print(json.dumps({"config": cfg["_path"], "slack": slack is not None,
                              "ok": True}, sort_keys=True))
            return 0
        report = Tick(cfg, gitea, slack, dry).run()
    except SetupError as error:
        print(f"scrum_master: unusable setup: {error}", file=sys.stderr)
        return 2
    except RuntimeError as error:
        print(f"scrum_master: {error}", file=sys.stderr)
        return 2
    print(json.dumps(report, indent=2, sort_keys=True))
    for error in report["errors"]:
        print(f"scrum_master: ERROR: {error}", file=sys.stderr)
    return 1 if report["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
