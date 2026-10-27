#!/usr/bin/env python3
"""capabilities.py: what each provider can do, what a job requires, and who can take it.

Bamboo-style capabilities (docs/plans/provider-capabilities.md Sections 2-5). A provider
advertises abilities; a job declares the abilities it requires; a provider may take a job only
when its abilities are a superset of the job's requires. This is a pure matcher: it knows
nothing about repos.toml (repoconfig.py owns per-repo grants) and never runs a provider.

Abilities are exactly plan, review, prototype, test-author and resolve. The hard ceiling is
static and lives only here: every provider may do all five except agy, which never resolves
(it has no deny list; resolving would need --dangerously-skip-permissions). repoconfig.py
reads the ceiling through ceiling(). An operator may narrow one provider on this host with
AGENT_POOL_CEILING_<PROVIDER> (for example AGENT_POOL_CEILING_GROK=review,plan); it never
widens past the ceiling (an ability above it is dropped with a warning) and an unknown
ability in it is an error (exit 2). Unset or blank means no narrowing.

The host-wide roster, AGENT_POOL_ROSTER, is the set of providers whose prods run on this host.
Its one source is repos.toml's [pool].providers, printed by `repoconfig.py roster`; it is not
a second list anyone maintains. For one job, the roster that counts is REPO_ROSTER: the
providers in AGENT_POOL_ROSTER that the job's own repo grants the job's ability, printed by
`repoconfig.py roster --repo R --ability A`. A grant on another repo never counts.

A job is unsatisfiable only when no provider in that roster can take it. The calling tick's
own PROVIDER_ORDER never decides that: an agy-only tick must not give up on a resolve job that
a claude tick on the same host takes. check-queue therefore takes the roster (--roster)
separately from the tick's order (--order), and partitions the capable providers:

  C_roster      roster providers whose abilities cover the requires
  C_configured  C_roster providers in --order, minus --unconfigured (this tick's preflight
                failures: missing binary, model or prompt)
  C_eligible    C_configured providers not in a provider cooldown, and none at all while
                faults/gates.json pauses gate-dependent jobs (resolve, test-author)

and prints one verdict:

  unsatisfiable     C_roster is empty: nobody on this host can ever take it (needs-human)
  elsewhere         C_roster has providers, none of them in --order: another tick's job
  setup-fault       capable providers are in --order but all failed this tick's preflight
  gates-paused      the job needs the gate sandbox and faults/gates.json is recorded
  waiting-cooldown  every configured capable provider is cooling down (wait_secs says how long)
  claimable         C_eligible is not empty

Subcommands:
  ceiling --provider P         P's static hard ceiling, comma-separated (no env narrowing)
  abilities --provider P       P's effective abilities: the ceiling narrowed by
                               AGENT_POOL_CEILING_<P>
  match --order CSV --requires CSV
                               print the providers in --order whose abilities cover --requires,
                               one per line, in order; exit 1 if none
  parse-requires --labels JSON [--body FILE] --default-job J
                               print the job's requires, sorted and comma-separated. Ability
                               labels (agent:plan, agent:review, agent:prototype,
                               agent:test-author, agent:resolve) win; else the last
                               <!-- agent-pool-job: requires=a,b --> directive in FILE; else J
                               (a settled default requires nothing and prints an empty line).
                               --labels is a JSON list of names or of {"name": ...} objects.
  check-queue --order CSV --requires CSV [--roster CSV] [--unconfigured CSV]
                               print the partition and verdict as one JSON object. --roster
                               defaults to the AGENT_POOL_ROSTER environment variable (a CSV
                               the caller exported from `repoconfig.py roster`); with neither,
                               it refuses (exit 2) rather than fall back to --order. An
                               explicit --roster "" is an empty roster (unsatisfiable).

Environment: AGENT_POOL_CEILING_<PROVIDER>, AGENT_POOL_ROSTER, AGENT_POOL_STATE (cooldowns and
faults/gates.json), AGENT_POOL_NOW.

Exit codes: 0 done; 1 match found nobody; 2 bad arguments or configuration.
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path

import cooldown
import poolstate

ABILITIES = ("plan", "review", "prototype", "test-author", "resolve")
PROVIDERS = ("claude", "cursor", "grok", "agy", "codex")
CEILING = {p: frozenset(ABILITIES) for p in PROVIDERS}
CEILING["agy"] = frozenset(ABILITIES) - {"resolve"}
GATED = frozenset({"resolve", "test-author"})
ABILITY_LABELS = {f"agent:{a}": a for a in ABILITIES}
DIRECTIVE = re.compile(r"<!--\s*agent-pool-job:\s*(.*?)-->", re.S)
_FIELD = re.compile(r"([a-z_-]+)=(\S+)")


class CapabilityError(Exception):
    """An argument or the environment names something unknown; nothing should be decided."""


def _ordered(found: set[str]) -> list[str]:
    return [a for a in ABILITIES if a in found]


def _abilities_csv(where: str, text: str) -> set[str]:
    found = {x.strip() for x in text.split(",") if x.strip()}
    unknown = sorted(found - set(ABILITIES))
    if unknown:
        raise CapabilityError(f"{where}: unknown ability {unknown[0]!r} "
                              f"(expected one of {', '.join(ABILITIES)})")
    return found


def _providers_csv(where: str, text: str) -> list[str]:
    found: list[str] = []
    for p in (x.strip() for x in text.split(",")):
        if not p:
            continue
        if p not in PROVIDERS:
            raise CapabilityError(f"{where}: unknown provider {p!r} (expected one of {', '.join(PROVIDERS)})")
        if p not in found:
            found.append(p)
    return found


def ceiling(provider: str) -> list[str]:
    """The provider's static hard ceiling, never narrowed by the environment."""
    if provider not in PROVIDERS:
        return []
    return _ordered(set(CEILING[provider]))


def abilities(provider: str) -> list[str]:
    """The provider's abilities on this host: the ceiling narrowed by AGENT_POOL_CEILING_<P>."""
    if provider not in PROVIDERS:
        return []
    var = f"AGENT_POOL_CEILING_{provider.upper()}"
    raw = os.environ.get(var, "").strip()
    if not raw:
        return ceiling(provider)
    narrowed = _abilities_csv(var, raw)
    for ability in sorted(narrowed - CEILING[provider]):
        print(f"capabilities: warning: {var} lists {ability}, which {provider} can never take; ignored",
              file=sys.stderr)
    return _ordered(narrowed & CEILING[provider])


def requires_list(text: str) -> list[str]:
    found = _abilities_csv("--requires", text)
    if not found:
        raise CapabilityError("--requires is empty: a job that requires nothing runs no provider")
    return sorted(found)


def match(order: list[str], requires: list[str]) -> list[str]:
    """The providers in `order` whose abilities cover every ability in `requires`, in order."""
    return [p for p in order if set(requires) <= set(abilities(p))]


def parse_requires(labels: list[str], body: str, default_job: str) -> list[str]:
    """The job's requires: ability labels, else the last directive in body, else default_job."""
    from_labels = {ABILITY_LABELS[x] for x in labels if x in ABILITY_LABELS}
    if from_labels:
        return sorted(from_labels)
    for env in reversed(list(DIRECTIVE.finditer(body))):
        fields = dict(_FIELD.findall(env.group(1)))
        if "requires" in fields:
            found = _abilities_csv("agent-pool-job directive requires=", fields["requires"])
            if found:
                return sorted(found)
    if default_job == "settled":
        return []
    if default_job not in ABILITIES:
        raise CapabilityError(f"--default-job: unknown job {default_job!r} "
                              f"(expected settled or one of {', '.join(ABILITIES)})")
    return [default_job]


def check_queue(order: list[str], requires: list[str], roster: list[str],
                unconfigured: list[str] | None = None) -> dict:
    """The C_roster / C_configured / C_eligible partition for one job, and its verdict."""
    unconfigured = unconfigured or []
    c_roster = match(roster, requires)
    in_order = [p for p in order if p in c_roster]
    c_configured = [p for p in in_order if p not in unconfigured]
    now = poolstate.now()
    cooling = {p: cooldown.remaining(p, now) for p in c_configured}
    gates_fault = poolstate.state_dir() / "faults" / "gates.json"
    gated = bool(GATED & set(requires)) and gates_fault.exists()
    c_eligible = [] if gated else [p for p in c_configured if cooling[p] <= 0]
    doc: dict = {"requires": requires, "roster": roster, "order": order,
                 "c_roster": c_roster, "c_configured": c_configured, "c_eligible": c_eligible,
                 "satisfiable": bool(c_roster)}
    need = ",".join(requires)
    if not c_roster:
        doc.update(verdict="unsatisfiable",
                   reason=f"no provider in the roster ({', '.join(roster) or 'none'}) has [{need}]")
    elif not in_order:
        doc.update(verdict="elsewhere",
                   reason=f"{', '.join(c_roster)} in the roster can take [{need}], none of them in this "
                          f"tick's order ({', '.join(order) or 'none'})")
    elif not c_configured:
        doc.update(verdict="setup-fault",
                   reason=f"every capable provider in this tick's order failed its preflight "
                          f"({', '.join(in_order)})")
    elif gated:
        doc.update(verdict="gates-paused",
                   reason=f"[{need}] needs the gate sandbox and {gates_fault} is recorded")
    elif not c_eligible:
        first = min(c_configured, key=lambda p: cooling[p])
        doc.update(verdict="waiting-cooldown", wait_secs=round(cooling[first]),
                   reason=f"every capable provider is cooling down; {first} is free in {round(cooling[first])}s")
    else:
        doc.update(verdict="claimable", reason=f"{', '.join(c_eligible)} may take [{need}]")
    return doc


def _labels(text: str) -> list[str]:
    try:
        raw = json.loads(text)
    except ValueError as error:
        raise CapabilityError(f"--labels is not JSON: {error}") from None
    if not isinstance(raw, list):
        raise CapabilityError("--labels must be a JSON list")
    out = []
    for item in raw:
        name = item.get("name") if isinstance(item, dict) else item
        if not isinstance(name, str):
            raise CapabilityError("--labels must list label names or {\"name\": ...} objects")
        out.append(name)
    return out


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("action", choices=["ceiling", "abilities", "match", "parse-requires", "check-queue"])
    p.add_argument("--provider", default="")
    p.add_argument("--order", default="")
    p.add_argument("--requires", default="")
    p.add_argument("--roster")
    p.add_argument("--unconfigured", default="")
    p.add_argument("--labels", default="[]")
    p.add_argument("--body", default="")
    p.add_argument("--default-job", default="")
    a = p.parse_args()
    try:
        if a.action in ("ceiling", "abilities"):
            if a.provider not in PROVIDERS:
                p.error(f"--provider must be one of {', '.join(PROVIDERS)}")
            print(",".join(ceiling(a.provider) if a.action == "ceiling" else abilities(a.provider)))
            return 0
        if a.action == "parse-requires":
            if not a.default_job:
                p.error("--default-job is required")
            body = ""
            if a.body:
                try:
                    body = Path(a.body).read_text(errors="replace")
                except OSError as error:
                    raise CapabilityError(f"cannot read --body {a.body}: {error.strerror}") from None
            print(",".join(parse_requires(_labels(a.labels), body, a.default_job)))
            return 0
        order = _providers_csv("--order", a.order)
        requires = requires_list(a.requires)
        if a.action == "match":
            found = match(order, requires)
            for provider in found:
                print(provider)
            return 0 if found else 1
        roster_text = a.roster if a.roster is not None else os.environ.get("AGENT_POOL_ROSTER", "").strip()
        if a.roster is None and not roster_text:
            raise CapabilityError("no roster: pass --roster or set AGENT_POOL_ROSTER (from `repoconfig.py "
                                  "roster`); the tick's own --order never stands in for it")
        roster = _providers_csv("--roster", roster_text)
        for provider in order:
            if provider not in roster:
                print(f"capabilities: {provider} is in --order but not in the roster; it does not count "
                      "for this job", file=sys.stderr)
        unconfigured = _providers_csv("--unconfigured", a.unconfigured)
        print(json.dumps(check_queue(order, requires, roster, unconfigured), sort_keys=True))
        return 0
    except CapabilityError as error:
        print(f"capabilities: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
