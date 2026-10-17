#!/usr/bin/env python3
"""lease.py: per-PR job leases with a heartbeat and a monotonically increasing fence token.

One document per PR under $AGENT_POOL_STATE/leases/. It is never deleted, so the fence
token only ever goes up: each successful claim writes fence = previous + 1, whether the
previous holder released cleanly or simply stopped renewing.

A worker holds the job while, under the job lock, the document still names its worker
id and fence, is not released, and has not passed expires_at. The worker renews
(heartbeat) well inside the TTL. A lease that is released or past expires_at is
reclaimable, and reclaiming bumps the fence, which is what turns every later write by
the previous holder into a no-op.

Every Gitea label or comment write goes through `guard`: it takes the job lock, checks
the caller still holds the current fence, and only then runs the write, still under
the lock. A superseded worker cannot interleave a write between the check and the call.

`hold` folds in GiteaFence::issueHeldByHuman, minus its permanent-hold failure mode: a
claim label (or "status: in-progress") with no live lease behind it is not a human
hold. If the pool leased the PR and that lease lapsed, the hold died with it and the PR
is reclaimable now. If the pool never leased it (another automation, or a run from
before the pool), the hold expires one grace period after the pool first saw it.

Subcommands (all take --repo O/R --pr N):
  claim   --mode M --worker W --provider P [--ttl S]   print the new fence; exit 3 if live
  renew   --worker W --fence F [--ttl S]               extend expires_at; exit 4 if not held
  check   --worker W --fence F                         exit 0 if held, 4 if not
  guard   --worker W --fence F -- CMD...               run CMD under the lock iff held
  release --worker W --fence F [--outcome O]           mark released; exit 4 if not held
  show                                                 print the lease document (or {})
  hold    --labels JSON [--assignees JSON] --hold-labels CSV [--bot LOGIN] [--grace S]
          print one of: free live human expired orphan-pending orphan-expired, a tab,
          and the reason

Exit codes: 0 ok, 2 usage or unreadable lease, 3 a live lease is held by someone else,
4 the caller does not hold the current fence.
"""
import argparse
import json
import os
import subprocess
import sys

import poolstate

DEFAULT_TTL = 900
DEFAULT_GRACE = 3600
HUMAN_LABELS = {"review:needs-human"}


def lease_path(repo, pr):
    return poolstate.state_dir() / "leases" / f"{poolstate.slug(repo)}__{int(pr)}.json"


def ttl(arg):
    return float(arg if arg is not None else os.environ.get("AGENT_POOL_LEASE_TTL", DEFAULT_TTL))


def is_live(doc, now):
    return bool(doc) and doc.get("fence", 0) > 0 and not doc.get("released") \
        and now < float(doc.get("expires_at", 0))


def holds(doc, worker, fence, now):
    """Return None if (worker, fence) holds the job, else the reason it does not."""
    if not doc:
        return "no lease exists for this job"
    if doc.get("fence") != fence:
        return f"fence {fence} is stale; current fence is {doc.get('fence')}"
    if doc.get("worker") != worker:
        return f"fence {fence} belongs to {doc.get('worker')}, not {worker}"
    if doc.get("released"):
        return f"fence {fence} was already released"
    if now >= float(doc.get("expires_at", 0)):
        return f"fence {fence} expired at {doc.get('expires_at')}"
    return None


def read(path):
    doc = poolstate.load(path)
    if doc and doc.get("_unreadable"):
        sys.exit(f"lease: {path} is unreadable; refusing to guess who holds it")
    return doc


def cmd_claim(a, path):
    now = poolstate.now()
    doc = read(path) or {}
    if is_live(doc, now):
        print(f"lease: live, held by {doc['worker']} fence {doc['fence']} until {doc['expires_at']}",
              file=sys.stderr)
        return 3
    fence = int(doc.get("fence", 0)) + 1
    poolstate.save(path, {
        "version": 1, "repo": a.repo, "pr": a.pr, "mode": a.mode, "worker": a.worker,
        "provider": a.provider, "fence": fence, "claimed_at": now, "renewed_at": now,
        "expires_at": now + ttl(a.ttl), "released": False, "outcome": None,
        "previous": {k: doc.get(k) for k in ("worker", "fence", "released", "outcome")} if doc else None,
    })
    print(fence)
    return 0


def require_holder(a, path):
    now = poolstate.now()
    doc = read(path)
    reason = holds(doc, a.worker, a.fence, now)
    if reason:
        print(f"lease: {a.repo}#{a.pr}: {reason}", file=sys.stderr)
        return None, now
    return doc, now


def cmd_renew(a, path):
    doc, now = require_holder(a, path)
    if doc is None:
        return 4
    doc.update(renewed_at=now, expires_at=now + ttl(a.ttl))
    if a.provider:
        doc["provider"] = a.provider
    poolstate.save(path, doc)
    return 0


def cmd_check(a, path):
    doc, _ = require_holder(a, path)
    return 0 if doc is not None else 4


def cmd_guard(a, path):
    doc, _ = require_holder(a, path)
    if doc is None:
        print(f"lease: write blocked for {a.worker}: {' '.join(a.command)[:200]}", file=sys.stderr)
        return 4
    if not a.command:
        print("lease: guard needs a command after --", file=sys.stderr)
        return 2
    return subprocess.run(a.command).returncode


def cmd_release(a, path):
    doc, now = require_holder(a, path)
    if doc is None:
        return 4
    doc.update(released=True, released_at=now, outcome=a.outcome)
    poolstate.save(path, doc)
    return 0


def cmd_show(a, path):
    print(json.dumps(read(path) or {}, indent=2, sort_keys=True))
    return 0


def cmd_hold(a, path):
    now = poolstate.now()
    doc = read(path) or {}
    labels = set(json.loads(a.labels or "[]"))
    assignees = [x for x in json.loads(a.assignees or "[]") if x]
    hold_labels = {x.strip() for x in a.hold_labels.split(",") if x.strip()}
    grace = float(a.grace if a.grace is not None else os.environ.get("AGENT_POOL_ORPHAN_GRACE", DEFAULT_GRACE))

    def out(state, reason):
        print(f"{state}\t{reason}")
        return 0

    if is_live(doc, now):
        return out("live", f"held by {doc['worker']} fence {doc['fence']} until {doc['expires_at']:.0f}")
    humans = [x for x in assignees if x != a.bot]
    if humans:
        return out("human", "assigned to " + ",".join(humans))
    if labels & HUMAN_LABELS:
        return out("human", "labelled " + ",".join(sorted(labels & HUMAN_LABELS)))
    held_by = sorted(labels & hold_labels)
    if not held_by:
        if doc.get("orphan_seen_at") is not None:
            doc.pop("orphan_seen_at")
            poolstate.save(path, doc)
        return out("free", "no hold label")
    if doc.get("fence", 0) > 0 and not doc.get("released"):
        return out("expired", f"{','.join(held_by)} left by {doc.get('worker')} fence {doc['fence']}, "
                              f"whose lease expired at {float(doc.get('expires_at', 0)):.0f}")
    seen = doc.get("orphan_seen_at")
    if seen is None:
        doc["orphan_seen_at"] = now
        poolstate.save(path, doc)
        return out("orphan-pending", f"{','.join(held_by)} with no pool lease; first seen now, "
                                     f"reclaimable after {grace:.0f}s")
    if now - float(seen) >= grace:
        return out("orphan-expired", f"{','.join(held_by)} with no pool lease for {now - float(seen):.0f}s")
    return out("orphan-pending", f"{','.join(held_by)} with no pool lease for {now - float(seen):.0f}s "
                                 f"of {grace:.0f}s grace")


def main():
    argv = sys.argv[1:]
    command = []
    if "--" in argv:
        split = argv.index("--")
        argv, command = argv[:split], argv[split + 1:]
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("action", choices=["claim", "renew", "check", "guard", "release", "show", "hold"])
    p.add_argument("--repo", required=True)
    p.add_argument("--pr", required=True, type=int)
    p.add_argument("--mode", default="")
    p.add_argument("--worker")
    p.add_argument("--provider", default="")
    p.add_argument("--fence", type=int)
    p.add_argument("--ttl", type=float)
    p.add_argument("--outcome")
    p.add_argument("--labels")
    p.add_argument("--assignees")
    p.add_argument("--hold-labels", default="")
    p.add_argument("--bot", default="")
    p.add_argument("--grace", type=float)
    a = p.parse_args(argv)
    a.command = command
    if a.action in ("claim", "renew", "check", "guard", "release") and not a.worker:
        p.error("--worker is required")
    if a.action in ("renew", "check", "guard", "release") and a.fence is None:
        p.error("--fence is required")
    path = lease_path(a.repo, a.pr)
    handler = globals()["cmd_" + a.action]
    if a.action == "show":
        return handler(a, path)
    with poolstate.locked(path):
        return handler(a, path)


if __name__ == "__main__":
    sys.exit(main())
