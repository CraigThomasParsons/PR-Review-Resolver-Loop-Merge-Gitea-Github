#!/usr/bin/env python3
"""claim-record.py: write-once per-job claim records, fenced by attempt_id (issue #1).

One record per PR under $AGENT_POOL_STATE/claims/<repo>__<pr>.json:

  {"version": 2, "repo_slug": ..., "issue_number": N, "provider": ..., "worker_id": ...,
   "attempt_id": "<uuid4>", "branch": ..., "worktree": ..., "job": "review|resolve",
   "claimed_at": "...Z", "expected_deadline_at": "...Z"}

A record is never renewed. expected_deadline_at is absolute, computed once at claim time,
and staleness is simply now > expected_deadline_at. Every controller-mediated write
(label, comment, push) runs through `guard` or `release`, which take the job lock, re-read
the record and act only if it still carries the caller's attempt_id. A superseded attempt
therefore cannot publish, release or relabel, whether or not it noticed it was superseded.

Ordering (the Gitea label is authoritative, the record is a cache):
  claim   writes the record, then runs the label flip, both under the job lock; if the
          flip fails the record is removed again
  release runs the label flip, then deletes the record; if the flip fails the record stays
  requeue (a stale attempt) flips claimed -> ready, then deletes the record

`reconcile` applies issue #1's table under the job lock, against labels read live from
Gitea at that moment (never a listing taken earlier in the tick):
  claimed + record     -> live, or stale once past expected_deadline_at
  claimed + no record  -> relabel to needs-human (no deadline can be computed; do not guess)
  not claimed + record -> the release already happened; delete the orphaned record
  neither              -> free

A provider fallback inside one job is a new attempt (`reattempt`): a fresh attempt_id and
deadline naming the new provider, written atomically over the old one. Records stay
write-once, the record always names the provider actually running, and any straggler from
the previous provider is fenced off.

`hold` keeps GiteaFence::issueHeldByHuman's idea without its permanent-hold failure: a
"status: in-progress" style label with no live claim behind it is not a human hold; it
expires one grace period after the pool first saw it.

Subcommands (all take --repo O/R --pr N):
  claim     --worker W --provider P [--job J] [--branch B] [--worktree D] [--deadline-secs S] [-- CMD...]
  reattempt --attempt A --provider P [--worktree D] [--deadline-secs S]   print the new attempt_id
  check     --attempt A                     exit 0 if A is the current attempt, else 4
  guard     --attempt A -- CMD...           run CMD under the lock iff A is current
  release   --attempt A [-- CMD...]         run CMD, then delete the record, iff A is current
  requeue   --attempt A --adapter F --claimed L --ready L    stale attempts only
  reconcile --adapter F --claimed L --needs-human L          print state<TAB>attempt<TAB>provider
  show                                      print the record (or {})
  hold      --labels JSON [--assignees JSON] --hold-labels CSV [--bot B] [--grace S]

Exit codes: 0 ok; 2 usage or unreadable record; 3 a claim already exists; 4 the attempt is
not current (or, for requeue, not stale); 5 the claim's label flip failed and was rolled back.
"""
import argparse
import datetime
import json
import os
import subprocess
import sys
import uuid

import poolstate

DEFAULT_DEADLINE = 2700
DEFAULT_GRACE = 3600
HUMAN_LABELS = {"agent:needs-human", "review:needs-human"}


def iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def epoch(text):
    return datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=datetime.timezone.utc).timestamp()


def claim_path(repo, pr):
    return poolstate.state_dir() / "claims" / f"{poolstate.slug(repo)}__{int(pr)}.json"


def hold_path(repo, pr):
    return poolstate.state_dir() / "holds" / f"{poolstate.slug(repo)}__{int(pr)}.json"


def readable(doc):
    return bool(doc) and not doc.get("_unreadable") and bool(doc.get("attempt_id")) \
        and bool(doc.get("expected_deadline_at"))


def is_stale(doc, now):
    return now > epoch(doc["expected_deadline_at"])


def deadline_secs(arg):
    return float(arg if arg is not None else os.environ.get("AGENT_POOL_DEADLINE_SECS", DEFAULT_DEADLINE))


def run(command, quiet=False):
    """Run CMD; quiet keeps its stdout off ours, where claim prints the attempt_id."""
    if not command:
        return 0
    return subprocess.run(command, stdout=subprocess.DEVNULL if quiet else None).returncode


def remove(path):
    try:
        path.unlink()
    except FileNotFoundError:
        pass


def new_record(a, now, previous=None):
    rec = {
        "version": 2, "repo_slug": a.repo, "issue_number": a.pr, "provider": a.provider,
        "worker_id": a.worker, "attempt_id": str(uuid.uuid4()), "branch": a.branch,
        "worktree": a.worktree, "job": a.job, "claimed_at": iso(now),
        "expected_deadline_at": iso(now + deadline_secs(a.deadline_secs)),
    }
    if previous:
        rec.update(worker_id=previous["worker_id"], branch=previous.get("branch"),
                   job=previous.get("job"), worktree=a.worktree or previous.get("worktree"),
                   supersedes=previous["attempt_id"])
    return rec


def current(path, attempt):
    """Return the record if `attempt` is its current attempt_id, else None (with a reason on stderr)."""
    doc = poolstate.load(path)
    if not doc:
        print(f"claim: no claim record; attempt {attempt} is not current", file=sys.stderr)
        return None
    if doc.get("_unreadable"):
        print("claim: record unreadable; refusing to act on it", file=sys.stderr)
        return None
    if doc.get("attempt_id") != attempt:
        print(f"claim: attempt {attempt} superseded by {doc.get('attempt_id')}", file=sys.stderr)
        return None
    return doc


def cmd_claim(a, path):
    doc = poolstate.load(path)
    if doc:
        state = "unreadable" if doc.get("_unreadable") else f"attempt {doc.get('attempt_id')} by {doc.get('worker_id')}"
        print(f"claim: {a.repo}#{a.pr} already claimed ({state})", file=sys.stderr)
        return 3
    rec = new_record(a, poolstate.now())
    poolstate.save(path, rec)
    if run(a.command, quiet=True) != 0:
        remove(path)
        print("claim: label flip failed; claim record rolled back", file=sys.stderr)
        return 5
    print(rec["attempt_id"])
    return 0


def cmd_reattempt(a, path):
    doc = current(path, a.attempt)
    if doc is None:
        return 4
    rec = new_record(a, poolstate.now(), previous=doc)
    poolstate.save(path, rec)
    print(rec["attempt_id"])
    return 0


def cmd_check(a, path):
    return 0 if current(path, a.attempt) is not None else 4


def cmd_guard(a, path):
    if current(path, a.attempt) is None:
        print(f"claim: write blocked: {' '.join(a.command)[:200]}", file=sys.stderr)
        return 4
    if not a.command:
        print("claim: guard needs a command after --", file=sys.stderr)
        return 2
    return run(a.command)


def cmd_release(a, path):
    if current(path, a.attempt) is None:
        return 4
    rc = run(a.command, quiet=True)
    if rc != 0:
        print("claim: release label flip failed; record kept for reconciliation", file=sys.stderr)
        return rc
    remove(path)
    return 0


def labels_live(a):
    out = subprocess.run([sys.executable, a.adapter, "labels", "--repo", a.repo, "--pr", str(a.pr)],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit(f"claim: could not read live labels: {out.stderr.strip()[:200]}")
    return set(json.loads(out.stdout or "[]"))


def relabel(a, remove_label, add_label):
    return subprocess.run([sys.executable, a.adapter, "label", "--repo", a.repo, "--pr", str(a.pr),
                           "--remove", remove_label, "--add", add_label]).returncode


def cmd_requeue(a, path):
    doc = current(path, a.attempt)
    if doc is None:
        return 4
    if not is_stale(doc, poolstate.now()):
        print(f"claim: attempt {a.attempt} is not past {doc['expected_deadline_at']}", file=sys.stderr)
        return 4
    if relabel(a, a.claimed, a.ready) != 0:
        print("claim: requeue label flip failed; record kept", file=sys.stderr)
        return 1
    remove(path)
    print(f"{doc.get('provider', '')}\t{doc.get('worker_id', '')}")
    return 0


def cmd_reconcile(a, path):
    labels = labels_live(a)
    doc = poolstate.load(path)
    if a.claimed in labels:
        if readable(doc):
            state = "stale" if is_stale(doc, poolstate.now()) else "live"
            print(f"{state}\t{doc['attempt_id']}\t{doc.get('provider', '')}\t{doc['expected_deadline_at']}")
            return 0
        if relabel(a, a.claimed, a.needs_human) != 0:
            print("error\t\t\tneeds-human relabel failed")
            return 1
        remove(path)
        print("needs-human\t\t\tlabelled claimed with no readable claim record")
        return 0
    if doc:
        remove(path)
        print(f"orphan-dropped\t{(doc or {}).get('attempt_id', '')}\t{(doc or {}).get('provider', '')}\t")
        return 0
    print("free\t\t\t")
    return 0


def cmd_show(a, path):
    print(json.dumps(poolstate.load(path) or {}, indent=2, sort_keys=True))
    return 0


def cmd_hold(a, path):
    now = poolstate.now()
    labels = set(json.loads(a.labels or "[]"))
    assignees = [x for x in json.loads(a.assignees or "[]") if x]
    hold_labels = {x.strip() for x in a.hold_labels.split(",") if x.strip()}
    grace = float(a.grace if a.grace is not None else os.environ.get("AGENT_POOL_ORPHAN_GRACE", DEFAULT_GRACE))
    doc = poolstate.load(path)
    hp = hold_path(a.repo, a.pr)
    seen_doc = poolstate.load(hp) or {}

    def out(state, reason):
        print(f"{state}\t{reason}")
        return 0

    if readable(doc) and not is_stale(doc, now):
        return out("live", f"claimed by {doc['worker_id']} attempt {doc['attempt_id']}")
    humans = [x for x in assignees if x != a.bot]
    if humans:
        return out("human", "assigned to " + ",".join(humans))
    if labels & HUMAN_LABELS:
        return out("human", "labelled " + ",".join(sorted(labels & HUMAN_LABELS)))
    held_by = sorted(labels & hold_labels)
    if not held_by:
        remove(hp)
        return out("free", "no hold label")
    seen = seen_doc.get("first_seen")
    if seen is None:
        poolstate.save(hp, {"first_seen": now, "labels": held_by})
        return out("hold-pending", f"{','.join(held_by)} with no live claim; first seen now, "
                                   f"expires after {grace:.0f}s")
    if now - float(seen) >= grace:
        return out("hold-expired", f"{','.join(held_by)} with no live claim for {now - float(seen):.0f}s")
    return out("hold-pending", f"{','.join(held_by)} with no live claim for {now - float(seen):.0f}s "
                               f"of {grace:.0f}s grace")


def main():
    argv = sys.argv[1:]
    command = []
    if "--" in argv:
        split = argv.index("--")
        argv, command = argv[:split], argv[split + 1:]
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("action", choices=["claim", "reattempt", "check", "guard", "release", "requeue",
                                      "reconcile", "show", "hold"])
    p.add_argument("--repo", required=True)
    p.add_argument("--pr", required=True, type=int)
    p.add_argument("--worker")
    p.add_argument("--provider", default="")
    p.add_argument("--job", default="")
    p.add_argument("--branch", default="")
    p.add_argument("--worktree", default="")
    p.add_argument("--deadline-secs", type=float)
    p.add_argument("--attempt")
    p.add_argument("--adapter")
    p.add_argument("--claimed", default="agent:claimed")
    p.add_argument("--ready", default="agent:ready")
    p.add_argument("--needs-human", default="agent:needs-human")
    p.add_argument("--labels")
    p.add_argument("--assignees")
    p.add_argument("--hold-labels", default="")
    p.add_argument("--bot", default="")
    p.add_argument("--grace", type=float)
    a = p.parse_args(argv)
    a.command = command
    if a.action == "claim" and not a.worker:
        p.error("--worker is required")
    if a.action in ("reattempt", "check", "guard", "release", "requeue") and not a.attempt:
        p.error("--attempt is required")
    if a.action in ("requeue", "reconcile") and not a.adapter:
        p.error("--adapter is required")
    path = claim_path(a.repo, a.pr)
    handler = globals()["cmd_" + a.action]
    if a.action in ("show", "hold"):
        return handler(a, path)
    with poolstate.locked(path):
        return handler(a, path)


if __name__ == "__main__":
    sys.exit(main())
