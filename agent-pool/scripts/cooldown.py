#!/usr/bin/env python3
"""cooldown.py: per-provider cooldowns after a usage or credit limit, plus setup-fault reports.

One file per provider under $AGENT_POOL_STATE/cooldowns/<provider>.json. A classified
limit records a strike; the cooldown is base * 2^(strikes-1), capped (1h, 2h, 4h, ...,
24h by default). A verified success clears the strikes. Strikes also lapse on their own
once a provider has gone a full cap length past its last cooldown without a new one.

Setup faults (a permission the pool's own configuration denied, a missing binary or
model) are NOT limits: retrying later will fail the same way until a person fixes the
setup, and a cooldown would only hide that. They go to faults/<provider>.json instead,
which nothing reads to gate selection, except faults/gates.json (the controller's gate
sandbox): while it exists, prod-common.sh claims no resolve job.

Ability-level cooldowns live in the same document, under "abilities": {"<ability>": {strikes,
since, until, seconds, reason}}, with the same strike, lapse and fixed-pause rules. A
provider-level cooldown (the top-level fields) blocks every ability; an ability-level one (a
timeout on a long resolve, say) blocks only that ability. The top-level fields keep their
shape, and "abilities" appears only once an ability has been recorded.

Subcommands (--ability A is optional everywhere; without it each acts on the provider level):
  record   --provider P --reason R [--seconds S] [--ability A]   add a strike; print
           "<until>\t<seconds>". With --seconds: pause S seconds with no strike (a timeout, not
           a limit). With --ability: the strike or pause is A's alone
  clear    --provider P [--ability A]   reset strikes after a verified success; with --ability,
           A's strikes and the provider's (any verified completion proves billing and login work)
  active   --provider P [--ability A]   exit 0 and print seconds left if cooling, else exit 1;
           with --ability, the longer of the provider's and A's cooldowns
  eligible --order a,b,c [--ability A[,B...]]   print providers not cooling, in order; exit 1 if
           none. With --ability, a provider must also have none of the named abilities cooling
  fault    --provider P --reason R [--ability A]   record a setup fault (no cooldown); with
           --ability it goes to faults/<provider>__<ability>.json
  show     --provider P [--ability A]   print the provider's cooldown document, or A's entry
           in it (or {})
"""
import argparse
import json
import os
import sys
from collections.abc import Iterable
from pathlib import Path

import poolstate


def base() -> float:
    return float(os.environ.get("AGENT_POOL_COOLDOWN_BASE", 3600))


def cap() -> float:
    return float(os.environ.get("AGENT_POOL_COOLDOWN_CAP", 86400))


def path_for(kind: str, provider: str, ability: str | None = None) -> Path:
    name = poolstate.slug(provider) + (f"__{poolstate.slug(ability)}" if ability else "")
    return poolstate.state_dir() / kind / f"{name}.json"


def read(path: Path) -> dict:
    doc = poolstate.load(path) or {}
    return {} if doc.get("_unreadable") else doc


def abilities_of(doc: dict) -> dict:
    found = doc.get("abilities")
    return dict(found) if isinstance(found, dict) else {}


def entry_of(doc: dict, ability: str) -> dict:
    found = abilities_of(doc).get(ability)
    return found if isinstance(found, dict) else {}


def left_in(entry: dict, now: float) -> float:
    return max(0.0, float(entry.get("until", 0)) - now)


def remaining(provider: str, now: float, abilities: Iterable[str] = ()) -> float:
    doc = read(path_for("cooldowns", provider))
    return max([left_in(doc, now)] + [left_in(entry_of(doc, x), now) for x in abilities])


def strike(entry: dict, now: float, seconds: float | None, reason: str) -> dict:
    """The next cooldown for one level: the provider's top-level fields, or one ability's entry."""
    strikes = int(entry.get("strikes", 0))
    if strikes and now - float(entry.get("until", 0)) > cap():
        strikes = 0
    if seconds is not None:
        # A fixed pause (a timeout): no strike, and never shortens a longer cooldown.
        until = max(now + seconds, float(entry.get("until", 0)))
    else:
        strikes += 1
        seconds = min(base() * 2 ** (strikes - 1), cap())
        until = now + seconds
    return {"strikes": strikes, "since": now, "until": until, "seconds": seconds, "reason": reason}


def with_abilities(doc: dict, abilities: dict) -> dict:
    if abilities:
        doc["abilities"] = abilities
    return doc


def cmd_record(a: argparse.Namespace) -> int:
    path = path_for("cooldowns", a.provider)
    with poolstate.locked(path):
        now = poolstate.now()
        doc = read(path)
        abilities = abilities_of(doc)
        if a.ability:
            entry = strike(entry_of(doc, a.ability), now, a.seconds, a.reason)
            abilities[a.ability] = entry
            top = {k: v for k, v in doc.items() if k != "abilities"} or \
                {"strikes": 0, "since": 0, "until": 0, "seconds": 0, "reason": ""}
            new = {**top, "provider": a.provider}
        else:
            entry = strike(doc, now, a.seconds, a.reason)
            new = {"provider": a.provider, **entry}
        poolstate.save(path, with_abilities(new, abilities))
    print(f"{entry['until']:.0f}\t{entry['seconds']:.0f}")
    return 0


def cmd_clear(a: argparse.Namespace) -> int:
    path = path_for("cooldowns", a.provider)
    with poolstate.locked(path):
        doc = read(path)
        if doc:
            now = poolstate.now()
            abilities = abilities_of(doc)
            if a.ability in abilities:
                abilities[a.ability] = {"strikes": 0, "until": 0, "cleared_at": now}
            poolstate.save(path, with_abilities({"provider": a.provider, "strikes": 0, "until": 0,
                                                 "cleared_at": now}, abilities))
    return 0


def cmd_active(a: argparse.Namespace) -> int:
    left = remaining(a.provider, poolstate.now(), a.abilities)
    if left > 0:
        print(f"{left:.0f}")
        return 0
    return 1


def cmd_eligible(a: argparse.Namespace) -> int:
    now = poolstate.now()
    found = [p for p in (x.strip() for x in a.order.split(","))
             if p and remaining(p, now, a.abilities) <= 0]
    for p in found:
        print(p)
    return 0 if found else 1


def cmd_fault(a: argparse.Namespace) -> int:
    path = path_for("faults", a.provider, a.ability)
    with poolstate.locked(path):
        doc = read(path)
        new = {"provider": a.provider, "count": int(doc.get("count", 0)) + 1,
               "last_at": poolstate.now(), "reason": a.reason}
        if a.ability:
            new["ability"] = a.ability
        poolstate.save(path, new)
    return 0


def cmd_show(a: argparse.Namespace) -> int:
    doc = read(path_for("cooldowns", a.provider))
    print(json.dumps(entry_of(doc, a.ability) if a.ability else doc, indent=2, sort_keys=True))
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("action", choices=["record", "clear", "active", "eligible", "fault", "show"])
    p.add_argument("--provider")
    p.add_argument("--reason", default="")
    p.add_argument("--order", default="")
    p.add_argument("--seconds", type=float)
    p.add_argument("--ability")
    a = p.parse_args()
    if a.action != "eligible" and not a.provider:
        p.error("--provider is required")
    a.abilities = [x.strip() for x in (a.ability or "").split(",") if x.strip()]
    # An empty --ability (an unset job variable, say) must not quietly act on the whole provider.
    if a.ability is not None and not a.abilities:
        p.error("--ability needs an ability name")
    if a.action != "eligible" and "," in (a.ability or ""):
        p.error(f"{a.action} takes one --ability, not a list")
    a.ability = a.abilities[0] if a.abilities else None
    return globals()["cmd_" + a.action](a)


if __name__ == "__main__":
    sys.exit(main())
