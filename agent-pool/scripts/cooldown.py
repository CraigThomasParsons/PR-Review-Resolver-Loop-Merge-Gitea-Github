#!/usr/bin/env python3
"""cooldown.py: per-provider cooldowns after a usage or credit limit, plus setup-fault reports.

One file per provider under $AGENT_POOL_STATE/cooldowns/<provider>.json. A classified
limit records a strike; the cooldown is base * 2^(strikes-1), capped (1h, 2h, 4h, ...,
24h by default). A verified success clears the strikes. Strikes also lapse on their own
once a provider has gone a full cap length past its last cooldown without a new one.

Setup faults (a permission the pool's own configuration denied, a missing binary or
model) are NOT limits: retrying later will fail the same way until a person fixes the
setup, and a cooldown would only hide that. They go to faults/<provider>.json instead,
which nothing reads to gate selection.

Subcommands:
  record   --provider P --reason R [--seconds S]   add a strike; print "<until>\t<seconds>".
           With --seconds: pause S seconds with no strike (a timeout, not a limit)
  clear    --provider P              reset strikes after a verified success
  active   --provider P              exit 0 and print seconds left if cooling, else exit 1
  eligible --order a,b,c             print providers not cooling, in order; exit 1 if none
  fault    --provider P --reason R   record a setup fault (no cooldown)
  show     --provider P              print the provider's cooldown document (or {})
"""
import argparse
import json
import os
import sys

import poolstate


def base():
    return float(os.environ.get("AGENT_POOL_COOLDOWN_BASE", 3600))


def cap():
    return float(os.environ.get("AGENT_POOL_COOLDOWN_CAP", 86400))


def path_for(kind, provider):
    return poolstate.state_dir() / kind / f"{poolstate.slug(provider)}.json"


def read(path):
    doc = poolstate.load(path) or {}
    return {} if doc.get("_unreadable") else doc


def remaining(provider, now):
    doc = read(path_for("cooldowns", provider))
    return max(0.0, float(doc.get("until", 0)) - now)


def cmd_record(a):
    path = path_for("cooldowns", a.provider)
    with poolstate.locked(path):
        now = poolstate.now()
        doc = read(path)
        strikes = int(doc.get("strikes", 0))
        if strikes and now - float(doc.get("until", 0)) > cap():
            strikes = 0
        if a.seconds is not None:
            # A fixed pause (a timeout): no strike, and never shortens a longer cooldown.
            seconds = a.seconds
            until = max(now + seconds, float(doc.get("until", 0)))
        else:
            strikes += 1
            seconds = min(base() * 2 ** (strikes - 1), cap())
            until = now + seconds
        poolstate.save(path, {"provider": a.provider, "strikes": strikes, "since": now,
                              "until": until, "seconds": seconds, "reason": a.reason})
    print(f"{until:.0f}\t{seconds:.0f}")
    return 0


def cmd_clear(a):
    path = path_for("cooldowns", a.provider)
    with poolstate.locked(path):
        if read(path):
            poolstate.save(path, {"provider": a.provider, "strikes": 0, "until": 0,
                                  "cleared_at": poolstate.now()})
    return 0


def cmd_active(a):
    left = remaining(a.provider, poolstate.now())
    if left > 0:
        print(f"{left:.0f}")
        return 0
    return 1


def cmd_eligible(a):
    now = poolstate.now()
    found = [p for p in (x.strip() for x in a.order.split(",")) if p and remaining(p, now) <= 0]
    for p in found:
        print(p)
    return 0 if found else 1


def cmd_fault(a):
    path = path_for("faults", a.provider)
    with poolstate.locked(path):
        doc = read(path)
        poolstate.save(path, {"provider": a.provider, "count": int(doc.get("count", 0)) + 1,
                              "last_at": poolstate.now(), "reason": a.reason})
    return 0


def cmd_show(a):
    print(json.dumps(read(path_for("cooldowns", a.provider)), indent=2, sort_keys=True))
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("action", choices=["record", "clear", "active", "eligible", "fault", "show"])
    p.add_argument("--provider")
    p.add_argument("--reason", default="")
    p.add_argument("--order", default="")
    p.add_argument("--seconds", type=float)
    a = p.parse_args()
    if a.action != "eligible" and not a.provider:
        p.error("--provider is required")
    return globals()["cmd_" + a.action](a)


if __name__ == "__main__":
    sys.exit(main())
