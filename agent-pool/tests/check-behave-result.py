#!/usr/bin/env python3
"""check-behave-result.py: accept a Behave JSON result only when it proves a complete passing run.

Usage: check-behave-result.py RESULT_JSON

RESULT_JSON is Behave's `--format json` output: a list of features, each with "elements"
(scenarios, outline rows included) carrying a "status" and "steps" whose "result" has a
"status". Exit 0 only when at least one scenario ran and every scenario and every one of its
steps reports "passed". Zero scenarios (an empty or fully filtered run), a skipped, untested,
undefined, pending, failed or errored scenario or step, a step with no result, an unexpected
element type, or an unreadable document exits 1 with one line per problem. Behave's own exit
status is checked separately by verify-conduits.sh; neither is acceptance alone.
"""
import json
import sys
from typing import Any

SCENARIO_TYPES = ("scenario", "scenario_outline")


def problems(document: Any) -> tuple[int, list[str]]:
    """(number of scenarios, problems found); an empty problem list with a nonzero count passes."""
    if not isinstance(document, list):
        return 0, ["the result is not a list of features"]
    found: list[str] = []
    scenarios = 0
    for feature in document:
        if not isinstance(feature, dict):
            found.append("a feature entry is not an object")
            continue
        elements = feature.get("elements") or []
        if not isinstance(elements, list):
            found.append(f"feature {feature.get('name')!r} has malformed elements")
            continue
        for element in elements:
            if not isinstance(element, dict) or element.get("type") not in SCENARIO_TYPES:
                kind = element.get("type") if isinstance(element, dict) else type(element).__name__
                found.append(f"unexpected element type {kind!r} in feature {feature.get('name')!r}")
                continue
            scenarios += 1
            name = element.get("name")
            if element.get("status") != "passed":
                found.append(f"scenario {name!r} is {element.get('status') or 'without a status'}")
            steps = element.get("steps")
            if not isinstance(steps, list) or not steps:
                found.append(f"scenario {name!r} has no steps")
                continue
            for step in steps:
                result = step.get("result") if isinstance(step, dict) else None
                status = result.get("status") if isinstance(result, dict) else None
                if status != "passed":
                    label = f"{step.get('keyword', '')} {step.get('name', '')}".strip() if isinstance(step, dict) else "?"
                    found.append(f"scenario {name!r} step {label!r} is {status or 'without a result'}")
    if scenarios == 0:
        found.append("no scenario was executed")
    return scenarios, found


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check-behave-result.py RESULT_JSON")
        return 2
    try:
        with open(sys.argv[1], encoding="utf-8") as stream:
            document = json.load(stream)
    except (OSError, UnicodeDecodeError, ValueError) as error:
        print(f"FAIL the Behave result is unreadable: {type(error).__name__}")
        return 1
    count, found = problems(document)
    for problem in found:
        print(f"FAIL {problem}")
    if found:
        return 1
    print(f"ok   {count} scenario(s) passed with every step passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
