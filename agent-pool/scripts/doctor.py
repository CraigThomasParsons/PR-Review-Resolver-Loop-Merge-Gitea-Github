#!/usr/bin/env python3
"""doctor.py: the agent pool's doctor (issue #1). Run it through bin/doctor.sh.

It never invokes a provider CLI (claude, codex, cursor-agent, grok, agy or any other): it reads
claim records, tick locks, cooldowns and repos.toml, reads Gitea through the adapter, and writes
only through claim-record.py under the job lock. It must not itself be rate-limitable.

1. Claims: every claim record under $AGENT_POOL_STATE/claims, and every open PR labelled
   agent:claimed in a configured repo.
     claimed + record past expected_deadline_at  stale: fence and requeue; the provider cools
                                                   down unless its work was already published
     claimed + record whose tick is gone          dead-worker: fence and requeue, no cooldown
                                                   (the tick died, not the provider)
     claimed + live record                        left alone
     claimed + no record                          agent:needs-human with a comment
     record, PR not claimed                       left for the prod tick, which drops it
   A tick holds $AGENT_POOL_STATE/pool-<worker>-<repo>.lock for its whole run (its workers
   inherit it), so a lock file that exists with nobody holding it means the tick that wrote the
   claim is gone. A missing lock file is no evidence; only the deadline applies then.
   Fencing (claim-record.py fence) archives the record under claims/fenced/ and replaces it with
   a fence record carrying a fresh attempt_id and epoch + 1, then flips agent:claimed ->
   agent:ready. The superseded attempt can no longer guard a write or release, and its watcher
   kills its worker group.
2. Queue: every open agent:ready PR in a configured repo a prod could claim (not a draft, a bot
   PR or a skipped title, no human hold, no claim record, not already settled by its markers).
   Its job kind is derived as prod-common.sh derives it (a review marker for the head with
   findings means resolve, anything else review) and matched against the roster in repos.toml:
     no roster provider has the ability enabled on the repo  agent:needs-human with the reason
     enabled providers exist but none is installed here      agent:needs-human with the reason
     every enabled, installed provider is cooling down       left queued (waiting-cooldown)
     otherwise                                               left queued (claimable)
   The relabel goes through claim-record.py escalate, which re-reads the PR under the job lock
   and refuses if it was claimed, relabelled, assigned or pushed to meanwhile.

Only repos listed in repos.toml are written to; a claim on any other repo is reported only.
Nothing is ever deleted: a fenced record is archived first, and published marks, cooldowns and
worktrees are left in place.

Usage: doctor.py [--dry-run] [--report FILE] [--repo OWNER/NAME ...]
  --dry-run (or DOCTOR_DRY_RUN=1)  decide and report, write nothing to Gitea or the claims
  --report FILE                    also write the JSON report there (default
                                   $AGENT_POOL_STATE/doctor/report.json); it is always printed
  --repo                           only these repos

Environment: AGENT_POOL_STATE, AGENT_POOL_CONFIG, AGENT_POOL_ADAPTER, AGENT_POOL_MARKER,
AGENT_POOL_LABEL_{READY,CLAIMED,NEEDS_HUMAN}, AGENT_POOL_BOT, AGENT_POOL_HOLD_LABELS,
PR_LOOP_SKIP_PATTERN, and the provider binaries CLAUDE_BIN, CURSOR_AGENT_BIN, GROK_BIN, AGY_BIN,
CODEX_BIN (default ~/.local/bin/<cli>), checked for presence only, never run.

Exit codes: 0 done; 1 some action failed (listed under "errors"); 2 unusable config.
"""
import argparse
import datetime
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import types
from pathlib import Path
from typing import Any

import cooldown
import poolstate
import repoconfig

SCRIPTS = Path(__file__).resolve().parent
COMMON = Path(os.environ.get("AGENT_POOL_COMMON") or SCRIPTS.parent.parent / "skills/pr-loops-common")
ADAPTER = os.environ.get("AGENT_POOL_ADAPTER") or str(COMMON / "gitea-pr.py")
MARKER = os.environ.get("AGENT_POOL_MARKER") or str(COMMON / "marker.py")
CLAIMREC = str(SCRIPTS / "claim-record.py")
COOLDOWN = str(SCRIPTS / "cooldown.py")
READY = os.environ.get("AGENT_POOL_LABEL_READY", "agent:ready")
CLAIMED = os.environ.get("AGENT_POOL_LABEL_CLAIMED", "agent:claimed")
HUMAN = os.environ.get("AGENT_POOL_LABEL_NEEDS_HUMAN", "agent:needs-human")
HUMAN_LABELS = {HUMAN, "agent:needs-human", "review:needs-human"}
BOT = os.environ.get("AGENT_POOL_BOT", "")
HOLD_LABELS = {x.strip() for x in os.environ.get("AGENT_POOL_HOLD_LABELS", "status: in-progress").split(",") if x.strip()}
SKIP = os.environ.get("PR_LOOP_SKIP_PATTERN", r"docblock-backfill|^chore\(#152\)")
BINS = {"claude": ("CLAUDE_BIN", "claude"), "cursor": ("CURSOR_AGENT_BIN", "cursor-agent"),
        "grok": ("GROK_BIN", "grok"), "agy": ("AGY_BIN", "agy"), "codex": ("CODEX_BIN", "codex")}
CALL_TIMEOUT = 300


class Failed(Exception):
    """One read or write the doctor needed did not work."""


def log(message: str) -> None:
    line = f"{datetime.datetime.now().astimezone().isoformat(timespec='seconds')} [doctor] {message}"
    print(line, file=sys.stderr)
    with open(poolstate.state_dir() / "doctor.log", "a") as stream:
        stream.write(line + "\n")


def iso(ts: float) -> str:
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def epoch(text: str) -> float:
    return datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=datetime.timezone.utc).timestamp()


def call(argv: list[str]) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=CALL_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Failed(f"{Path(argv[1]).name} {argv[2]}: {type(error).__name__}") from None


def adapter(*args: str) -> Any:
    out = call([sys.executable, ADAPTER, *args])
    if out.returncode != 0:
        raise Failed(f"adapter {args[0]} failed: {out.stderr.strip()[:200]}")
    return json.loads(out.stdout or "null")


def load_marker() -> types.ModuleType:
    spec = importlib.util.spec_from_file_location("marker", MARKER)
    if spec is None or spec.loader is None:
        raise Failed(f"cannot load the marker reader {MARKER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def provider_bin(provider: str) -> str:
    var, cli = BINS[provider]
    return os.environ.get(var) or str(Path.home() / ".local/bin" / cli)


def installed(provider: str) -> bool:
    path = provider_bin(provider)
    return os.path.isabs(path) and os.path.isfile(path) and os.access(path, os.X_OK)


def derive_job(marker: types.ModuleType, comments: list[dict], head: str) -> tuple[str, str]:
    """(review|resolve|settled, why) the way prod-common.sh's derive_job reads the markers."""
    reviews = [(m.group(1), int(m.group(2))) for c in comments
               for m in [marker.MARKER.search(c.get("body") or "")] if m]
    latest = reviews[-1] if reviews else None
    if latest and latest[0] == head:
        if latest[1] > 0:
            return "resolve", ""
        return "settled", "the review of its head is already posted and clean"
    resolves = [r for c in comments for r in [marker.parse_resolve(c.get("body") or "")] if r]
    if latest and resolves and resolves[-1][0] == head and resolves[-1][1] == latest[0]:
        return "settled", "a resolve at its head already answers the latest review"
    return "review", ""


def escalate(repo: str, pr: int, src: str, body: str, head: str = "") -> tuple[bool, str]:
    with tempfile.NamedTemporaryFile("w", prefix="doctor-comment.", suffix=".md", delete=False) as stream:
        stream.write(body)
        body_file = stream.name
    try:
        argv = [sys.executable, CLAIMREC, "escalate", "--repo", repo, "--pr", str(pr), "--adapter", ADAPTER,
                "--claimed", CLAIMED, "--from", src, "--to", HUMAN, "--body-file", body_file, "--bot", BOT]
        if head:
            argv += ["--expect-head", head]
        out = call(argv)
    finally:
        os.unlink(body_file)
    return out.returncode == 0, out.stderr.strip()[:300]


class Doctor:
    def __init__(self, cfg: dict, marker: types.ModuleType, dry: bool) -> None:
        self.cfg, self.marker, self.dry = cfg, marker, dry
        self.state = poolstate.state_dir()
        self.now = poolstate.now()
        self.claims: list[dict] = []
        self.queue: list[dict] = []
        self.errors: list[str] = []

    def error(self, message: str) -> None:
        self.errors.append(message)
        log(f"ERROR: {message}")

    # ------------------------------------------------------------ claim records on disk
    def records(self) -> dict[str, dict[int, dict]]:
        found: dict[str, dict[int, dict]] = {}
        by_slug = {poolstate.slug(r): r for r in self.cfg["repos"]}
        for path in sorted((self.state / "claims").glob("*.json")):
            m = re.fullmatch(r"(.+)__(\d+)\.json", path.name)
            doc = poolstate.load(path)
            if not m or doc is None:
                continue
            if not isinstance(doc, dict) or not doc:
                doc = {"_unreadable": True}
            repo = doc.get("repo_slug") if not doc.get("_unreadable") else None
            found.setdefault(repo or by_slug.get(m.group(1), m.group(1)), {})[int(m.group(2))] = doc
        return found

    # ------------------------------------------------------------ one repo
    def repo(self, repo: str, records: dict[int, dict]) -> None:
        allowed = repo in self.cfg["repos"]
        try:
            listing = adapter("list", "--repo", repo, "--state", "open")
        except Failed as error:
            self.error(f"{repo}: cannot list open PRs ({error}); nothing decided for this repo")
            return
        prs = {int(p["number"]): p for p in listing or []}
        claimed = {n for n, p in prs.items() if CLAIMED in p.get("labels", [])}
        for pr in sorted(set(records) | (claimed if allowed else set())):
            self.claim(repo, pr, records.get(pr), prs.get(pr), allowed)
        if not allowed:
            return
        for pr, info in sorted(prs.items()):
            labels = info.get("labels", [])
            if READY in labels and CLAIMED not in labels and pr not in records:
                self.queued(repo, pr, info)

    def claim(self, repo: str, pr: int, doc: dict | None, info: dict | None, allowed: bool) -> None:
        entry: dict[str, Any] = {"repo": repo, "pr": pr, "state": "", "action": "none", "reason": ""}
        self.claims.append(entry)
        if doc is not None:
            entry.update(attempt=doc.get("attempt_id", ""), provider=doc.get("provider", ""),
                         worker_id=doc.get("worker_id", ""), deadline=doc.get("expected_deadline_at", ""))
        labels = (info or {}).get("labels", [])
        if doc is None:
            entry.update(state="no-record", reason=f"labelled {CLAIMED} with no claim record behind it, so no "
                                                   "deadline can be computed")
            body = (f"Automated agent pool doctor: this PR is labelled `{CLAIMED}`, but no claim record backs it on "
                    "the pool host, so no deadline can be computed and nothing can safely requeue it. A human "
                    f"needs to look; relabel it `{READY}` to queue it again.\n")
            self.act_escalate(entry, CLAIMED, body)
            return
        if doc.get("_unreadable") or not doc.get("attempt_id") or not doc.get("expected_deadline_at"):
            entry.update(state="unreadable", reason="the claim record cannot be read; the prod tick's reconcile "
                                                    "routes it")
            return
        if CLAIMED not in labels:
            entry.update(state="fenced" if doc.get("fenced_attempt") else "orphan",
                         reason=f"not labelled {CLAIMED}; the next prod tick drops the record")
            return
        worker = doc.get("worker_id", "")
        lock = self.state / f"pool-{poolstate.slug(worker)}-{poolstate.slug(repo)}.lock"
        if self.now > epoch(doc["expected_deadline_at"]):
            entry.update(state="stale", reason=f"past its deadline {doc['expected_deadline_at']}")
        elif poolstate.lock_abandoned(lock):
            entry.update(state="dead-worker", reason=f"the tick of {worker} that holds it is gone "
                                                     f"(its lock {lock.name} is free)")
        else:
            entry.update(state="live")
            return
        if not allowed:
            entry["action"] = "report-only"
            entry["reason"] += f"; {repo} is not in repos.toml, so the doctor does not touch it"
            return
        if self.dry:
            entry["action"] = "would-requeue"
            return
        argv = [sys.executable, CLAIMREC, "fence", "--repo", repo, "--pr", str(pr), "--attempt", doc["attempt_id"],
                "--adapter", ADAPTER, "--claimed", CLAIMED, "--ready", READY, "--reason", f"doctor: {entry['reason']}"]
        if entry["state"] == "dead-worker":
            argv += ["--owner-lock", str(lock)]
        try:
            out = call(argv)
        except Failed as error:
            out = subprocess.CompletedProcess(argv, 1, "", str(error))
        fenced = (out.stdout.strip().split("\t") + [""] * 3)[2]
        if fenced:
            entry["fence_attempt"] = fenced
        if out.returncode != 0:
            entry["action"] = "fenced-only" if fenced else "failed"
            self.error(f"{repo}#{pr}: could not fence and requeue attempt {doc['attempt_id'][:8]} "
                       f"({out.stderr.strip()[:200]})")
            if not fenced:
                return
        else:
            entry["action"] = "requeued"
            log(f"{repo}#{pr}: attempt {doc['attempt_id'][:8]} ({doc.get('provider') or 'no provider'}) "
                f"{entry['state']}: {entry['reason']}; fenced and requeued to {READY}")
        provider = doc.get("provider", "")
        published = (self.state / "published" / f"{poolstate.slug(repo)}__{pr}.{doc['attempt_id']}").exists()
        if entry["state"] == "stale" and provider in repoconfig.PROVIDERS and not published:
            cd = call([sys.executable, COOLDOWN, "record", "--provider", provider,
                       "--reason", "a claim passed its deadline with no result (doctor)"])
            entry["cooldown"] = provider if cd.returncode == 0 else ""
            if cd.returncode != 0:
                self.error(f"{repo}#{pr}: could not record a cooldown for {provider}")

    # ------------------------------------------------------------ the queue
    def queued(self, repo: str, pr: int, info: dict) -> None:
        entry: dict[str, Any] = {"repo": repo, "pr": pr, "head": info.get("head_sha", ""), "job": "",
                                 "state": "", "action": "none", "reason": ""}
        self.queue.append(entry)
        labels = set(info.get("labels", []))
        humans = [x for x in info.get("assignees", []) if x and x != BOT]
        if info.get("draft") or info.get("is_bot") or (SKIP and (re.search(SKIP, info.get("title", ""))
                                                                  or re.search(SKIP, info.get("head_ref", "")))):
            entry.update(state="skipped", reason="a draft, a bot PR or a skipped title; no prod claims it")
            return
        if humans or labels & (HUMAN_LABELS | HOLD_LABELS):
            entry.update(state="held", reason="held by " + ",".join(humans or sorted(labels & (HUMAN_LABELS | HOLD_LABELS))))
            return
        try:
            comments = adapter("comments", "--repo", repo, "--pr", str(pr)) or []
        except Failed as error:
            entry["state"] = "error"
            self.error(f"{repo}#{pr}: cannot read comments ({error})")
            return
        job, why = derive_job(self.marker, comments, entry["head"])
        entry["job"] = job
        if job == "settled":
            entry.update(state="settled", reason=f"{why}; the next prod tick settles it without a provider")
            return
        roster = self.cfg["providers"]
        per = {p: {"abilities": repoconfig.abilities(self.cfg, repo, p), "installed": installed(p),
                   "cooling_secs": round(cooldown.remaining(p, self.now))} for p in roster}
        entry["providers"] = per
        enabled = [p for p in roster if job in per[p]["abilities"]]
        ready = [p for p in enabled if per[p]["installed"]]
        if not enabled:
            entry.update(state="not-enabled", reason=f"{job} is not enabled on {repo} for any provider in the "
                                                     f"roster ({', '.join(roster) or 'none'})")
        elif not ready:
            entry.update(state="not-installed", reason=f"no provider that may take {job} on {repo} is installed "
                                                       f"on the pool host ({', '.join(enabled)})")
        elif all(per[p]["cooling_secs"] > 0 for p in ready):
            wait = min(per[p]["cooling_secs"] for p in ready)
            entry.update(state="waiting-cooldown", reason=f"every provider that may take {job} is cooling down; "
                                                          f"the first is free in {wait}s")
            return
        else:
            entry.update(state="claimable", reason=f"{', '.join(p for p in ready if per[p]['cooling_secs'] <= 0)} "
                                                    f"may take {job}")
            return
        body = (f"Automated agent pool doctor: this PR is queued (`{READY}`) for a {job} job, but {entry['reason']}. "
                f"No prod would ever claim it, so it is labelled `{HUMAN}` rather than waiting in the queue.\n\n"
                f"To hand it back to the pool, enable `{job}` for this repo in the pool's repos.toml (or install a "
                f"provider that may take it), then relabel it `{READY}`.\n")
        self.act_escalate(entry, READY, body, entry["head"])

    def act_escalate(self, entry: dict, src: str, body: str, head: str = "") -> None:
        repo, pr = entry["repo"], entry["pr"]
        if self.dry:
            entry["action"] = "would-needs-human"
            return
        try:
            ok, why = escalate(repo, pr, src, body, head)
        except Failed as error:
            ok, why = False, str(error)
        if ok:
            entry["action"] = "needs-human"
            log(f"{repo}#{pr}: {entry['state']}: {entry['reason']}; {src} -> {HUMAN}")
        elif "not escalated" in why or "has a claim record" in why:
            entry["action"] = "skipped"
            entry["reason"] += f" (left alone: {why.removeprefix('claim: ')})"
        else:
            entry["action"] = "failed"
            self.error(f"{repo}#{pr}: could not move it to {HUMAN} ({why})")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--report", default="")
    p.add_argument("--repo", action="append", default=[])
    a = p.parse_args()
    dry = a.dry_run or os.environ.get("DOCTOR_DRY_RUN", "").strip().lower() in ("1", "true", "yes", "on")
    state = poolstate.state_dir()
    report_path = Path(a.report) if a.report else state / "doctor" / "report.json"
    report: dict[str, Any] = {"version": 1, "generated_at": iso(poolstate.now()), "dry_run": dry,
                              "config": str(repoconfig.config_path()), "roster": [], "warnings": [],
                              "claims": [], "queue": [], "errors": []}
    rc = 0
    try:
        cfg = repoconfig.load()
        marker = load_marker()
    except (repoconfig.ConfigError, Failed, OSError, SyntaxError) as error:
        report["errors"].append(f"unusable setup: {error}")
        log(f"ERROR: unusable setup: {error}; nothing decided")
        rc = 2
    else:
        report["roster"], report["warnings"] = cfg["providers"], cfg["warnings"]
        doctor = Doctor(cfg, marker, dry)
        log(f"tick{' (dry run)' if dry else ''}: {len(cfg['repos'])} configured repo(s), "
            f"roster {','.join(cfg['providers']) or 'empty'}")
        records = doctor.records()
        repos = list(cfg["repos"]) + [r for r in records if r not in cfg["repos"]]
        if a.repo:
            repos = list(a.repo)
        for repo in repos:
            doctor.repo(repo, records.get(repo, {}))
        report.update(claims=doctor.claims, queue=doctor.queue, errors=doctor.errors)
        rc = 1 if doctor.errors else 0
    actions = [e["action"] for e in report["claims"] + report["queue"]]
    report["summary"] = {k: actions.count(k) for k in sorted(set(actions))}
    poolstate.save(report_path, report)
    print(json.dumps(report, indent=2, sort_keys=True))
    return rc


if __name__ == "__main__":
    sys.exit(main())
