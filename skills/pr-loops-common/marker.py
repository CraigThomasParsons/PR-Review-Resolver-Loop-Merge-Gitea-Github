#!/usr/bin/env python3
"""
Read the hidden markers the PR review and resolve loops leave on a pull request.

The review worker ends its posted comment with one HTML comment:

    <!-- pulse-review:v1 head=<40 hex sha> findings=<int> -->

The loop treats that marker, not GitHub's own review state, as the record of what was
reviewed. A PR whose latest marker names the current head has been reviewed already and is
skipped, so a re-run of the loop, a duplicate label event, or a crashed-and-restarted tick can
never post a second review of the same commit.

The resolve worker ends its comment with the companion:

    <!-- pulse-resolve:v1 head=<40 hex sha> reviewed=<40 hex sha> fixed=<int> noted=<int> deferred=<int> -->

`reviewed` names the head the findings were about, so a resolve run cannot be credited against a
review of some other commit. `fixed` and `deferred` are the per-finding disposition, and they
exist because a pushed commit is not evidence that the findings were dealt with: on the first
live run the resolver fixed two findings, left a third as a human decision, and the loop still
labelled the pull request resolved, because all it checked was that the head had moved.

`noted` counts findings left for the author that do not block merging: suggestions, conventions,
process ideas. It was split out of `deferred` on 2026-10-05 after a docs PR with eight findings,
three fixed and five of them preferences, landed on review:needs-human although nothing in it was
wrong. Only `deferred` (a blocking problem the resolver could not fix) stops a PR now. `noted` is
optional so markers written before the split still parse, as noted=0.

The agent pool's other abilities (docs/plans/provider-capabilities.md Section 1) leave their own
markers, parsed the same way (envelope first, key=value fields, extra keys ignored):

    <!-- pulse-plan:v1 head=<40 hex sha> -->
    <!-- pulse-prototype:v1 base=<40 hex sha> commit=<40 hex sha> attempt=<id> files=<int> -->
    <!-- pulse-test-author:v1 head=<40 hex sha> base=<40 hex sha> tests_changed=<int> -->

A prototype's commit lives only under a local controller ref and is never pushed; base is the
head it was built on.

Usage:
  marker.py latest  <pr>       prints "<head> <findings>" for the newest review marker
  marker.py count   <pr>       prints how many review markers the PR carries (round count)
  marker.py resolve <pr>       prints "<head> <reviewed> <fixed> <deferred> <noted>" for the
                               newest resolve marker, or nothing
  marker.py plan <pr>          prints "<head>" for the newest plan marker, or nothing
  marker.py prototype <pr>     prints "<base> <commit> <attempt> <files>", or nothing
  marker.py test-author <pr>   prints "<head> <base> <tests_changed>", or nothing

Shells out to the authenticated gh CLI; no token handling here.
"""

import json
import re
import os
import subprocess
from pathlib import Path
import sys

REPO = os.environ.get("PR_LOOP_REPO", "craigpars/AgileMedievalPeasantBoard")
MARKER = re.compile(r"<!--\s*pulse-review:v1\s+head=([0-9a-f]{40})\s+findings=(\d+)\s*-->")
# Envelope first, fields second. The original pinned an exact field ORDER with nothing
# between fixed= and deferred=, and on 2026-09-22 a resolve worker emitted
#   fixed=2 declined=1 deferred=0
# which that pattern could not match. A marker the gate cannot read is a resolve that can
# never be accepted, so the strictness bought nothing and cost a whole run. Parse the
# key=value pairs instead: extra keys are ignored, missing required keys still fail.
RESOLVE_ENVELOPE = re.compile(r"<!--\s*pulse-resolve:v1\s+(.*?)-->", re.S)
_FIELD = re.compile(r"([a-z_]+)=(\S+)")


def parse_resolve(body: str):
    """Return (head, reviewed, fixed, deferred, noted) for the first valid marker, else None."""
    for env in RESOLVE_ENVELOPE.finditer(body or ""):
        f = dict(_FIELD.findall(env.group(1)))
        head, reviewed = f.get("head", ""), f.get("reviewed", "")
        if not (re.fullmatch(r"[0-9a-f]{40}", head) and re.fullmatch(r"[0-9a-f]{40}", reviewed)):
            continue
        try:
            return head, reviewed, int(f["fixed"]), int(f["deferred"]), int(f.get("noted", 0))
        except (KeyError, ValueError):
            continue
    return None


_SHA = re.compile(r"[0-9a-f]{40}")
_ATTEMPT = re.compile(r"[A-Za-z0-9._-]+")
ENVELOPES = {kind: re.compile(r"<!--\s*pulse-" + kind + r":v1\s+(.*?)-->", re.S)
             for kind in ("plan", "prototype", "test-author")}


def _fields(kind: str, body: str):
    for env in ENVELOPES[kind].finditer(body or ""):
        yield dict(_FIELD.findall(env.group(1)))


def parse_plan(body: str):
    """Return (head,) for the first valid plan marker, else None."""
    for f in _fields("plan", body):
        if _SHA.fullmatch(f.get("head", "")):
            return (f["head"],)
    return None


def parse_prototype(body: str):
    """Return (base, commit, attempt, files) for the first valid prototype marker, else None."""
    for f in _fields("prototype", body):
        base, commit, attempt = f.get("base", ""), f.get("commit", ""), f.get("attempt", "")
        if not (_SHA.fullmatch(base) and _SHA.fullmatch(commit) and _ATTEMPT.fullmatch(attempt)):
            continue
        try:
            return base, commit, attempt, int(f["files"])
        except (KeyError, ValueError):
            continue
    return None


def parse_test_author(body: str):
    """Return (head, base, tests_changed) for the first valid test-author marker, else None."""
    for f in _fields("test-author", body):
        head, base = f.get("head", ""), f.get("base", "")
        if not (_SHA.fullmatch(head) and _SHA.fullmatch(base)):
            continue
        try:
            return head, base, int(f["tests_changed"])
        except (KeyError, ValueError):
            continue
    return None


PARSERS = {"resolve": parse_resolve, "plan": parse_plan, "prototype": parse_prototype,
           "test-author": parse_test_author}


def comments(pr: int) -> list[dict]:
    # Gitea, via the loops' adapter: one JSON array, already paginated there.
    adapter = str(Path(__file__).with_name("gitea-pr.py"))
    out = subprocess.run(
        [sys.executable, adapter, "comments", "--repo", REPO, "--pr", str(pr)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return json.loads(out or "[]")


def markers(pr: int) -> list[tuple[str, int]]:
    found = []
    for c in comments(pr):
        m = MARKER.search(c.get("body") or "")
        if m:
            found.append((m.group(1), int(m.group(2))))
    return found


def kind_markers(pr: int, kind: str) -> list[tuple]:
    found = []
    for c in comments(pr):
        parsed = PARSERS[kind](c.get("body") or "")
        if parsed:
            found.append(parsed)
    return found


def resolve_markers(pr: int) -> list[tuple[str, str, int, int, int]]:
    return kind_markers(pr, "resolve")


def main() -> None:
    if len(sys.argv) != 3 or sys.argv[1] not in ("latest", "count", *PARSERS):
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    pr = int(sys.argv[2])
    if sys.argv[1] in PARSERS:
        got = kind_markers(pr, sys.argv[1])
        if got:
            print(" ".join(str(x) for x in got[-1]))
        return
    found = markers(pr)
    if sys.argv[1] == "count":
        print(len(found))
        return
    if found:
        head, findings = found[-1]
        print(f"{head} {findings}")


if __name__ == "__main__":
    main()
