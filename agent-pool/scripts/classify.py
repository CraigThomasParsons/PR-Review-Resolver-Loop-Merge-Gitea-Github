#!/usr/bin/env python3
"""classify.py: read one headless provider run and say what kind of ending it was.

Usage: classify.py --provider P --exit RC --stdout FILE [--stderr FILE]

Prints one line, a verdict and a tab-separated reason:
  ok          the provider says it finished; verification decides whether it did the job
  setup       the pool's own setup got in the way: a tool call was denied or rejected, or
              the binary is missing. No cooldown; a person has to fix the configuration
  limit       a usage, credit or rate limit. The provider cools down and the job goes back
              to its trigger label
  incomplete  the provider ended without a usable result (crash, timeout, no result event)
              and no limit signature explains it. Verification still runs; a fast run with
              no marker is then treated as a limit by prod-common.sh

Setup faults are found by JSON key, never by prose: cursor tool events carrying
`rejected` or `permissionDenied`, agy's `denied_actions`, claude's `permission_denials`.
A run can exit 0 and report SUCCESS and still be a setup fault.

Limit signatures are only looked for when the provider itself reports failure (or, for
claude, in a short result that is nothing but the product's own limit message). A review
that discusses rate limiting must not read as a rate limit.
"""
import argparse
import json
import re
import sys

ANY_LIMIT = re.compile(
    r"\b429\b|too many requests|rate[ _-]?limit|quota[ _-]?exceeded|exceeded (?:your |the )?quota"
    r"|insufficient[ _-]?credits?", re.I)
# classify-pane.sh's PARKED product dialogs, plus the credit wall that started all this.
CLAUDE_LIMIT = re.compile(
    r"You've reached your .* limit|/usage-credits|Set up auto mode for your environment"
    r"|Select login method|log in to continue|purchase more credits|upgrade your plan to continue"
    r"|Credit balance is too low", re.I)
DENIAL_KEYS = ("rejected", "permissionDenied", "denied_actions", "permission_denials")
SHORT_RESULT = 400


def read(path):
    if not path:
        return ""
    try:
        with open(path, errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def parse_object(text):
    try:
        doc = json.loads(text)
        return doc if isinstance(doc, dict) else None
    except ValueError:
        # Some CLIs print a banner before the JSON; take the last line that parses.
        for line in reversed(text.strip().splitlines()):
            try:
                doc = json.loads(line)
                if isinstance(doc, dict):
                    return doc
            except ValueError:
                continue
    return None


def parse_events(text):
    events = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            doc = json.loads(line)
        except ValueError:
            continue
        if isinstance(doc, dict):
            events.append(doc)
    return events


def denials(node, path=""):
    """Yield (path, value) for every non-empty denial key anywhere in a JSON document."""
    if isinstance(node, dict):
        for key, value in node.items():
            here = f"{path}.{key}" if path else key
            if key in DENIAL_KEYS and value not in (None, False, "", [], {}):
                yield here, value
            else:
                yield from denials(value, here)
    elif isinstance(node, list):
        for i, value in enumerate(node):
            yield from denials(value, f"{path}[{i}]")


def describe(found):
    where, value = found[0]
    text = json.dumps(value)[:160]
    more = f" (+{len(found) - 1} more)" if len(found) > 1 else ""
    return f"{where}={text}{more}"


def classify(provider, rc, out, err):
    if rc in (126, 127):
        return "setup", f"{provider} binary missing or not executable (exit {rc})"

    docs, failed, result_text, why = [], rc != 0, "", f"exit {rc}"
    if provider == "cursor":
        docs = parse_events(out)
        results = [e for e in docs if e.get("type") == "result"]
        if not results:
            failed, why = True, "no result event in the stream"
        else:
            last = results[-1]
            result_text = str(last.get("result", ""))
            if last.get("is_error") or last.get("subtype") not in (None, "success"):
                failed, why = True, f"result event subtype={last.get('subtype')} is_error={last.get('is_error')}"
    else:
        doc = parse_object(out) if provider != "codex" else None
        if doc is not None:
            docs = [doc]
        if provider == "claude":
            if doc is None:
                failed, why = True, "no JSON result"
            else:
                result_text = str(doc.get("result", ""))
                if doc.get("is_error") or doc.get("subtype") not in (None, "success"):
                    failed, why = True, f"subtype={doc.get('subtype')} is_error={doc.get('is_error')}"
        elif provider == "agy":
            if rc == 124:
                failed, why = True, "timed out"
            elif doc is None:
                failed, why = True, "no JSON result"
            else:
                result_text = str(doc.get("result", doc.get("text", "")))
                if str(doc.get("status", "")).upper() != "SUCCESS":
                    failed, why = True, f"status={doc.get('status')}"
        elif provider == "grok":
            if doc is None:
                failed, why = True, "no JSON result"
            else:
                result_text = str(doc.get("text", ""))
                if doc.get("error"):
                    failed, why = True, f"error={str(doc.get('error'))[:120]}"
        elif provider == "codex":
            result_text = out[-SHORT_RESULT:]

    found = [d for doc in docs for d in denials(doc)]
    if found:
        return "setup", f"{provider} denied a tool call the worker needed: {describe(found)}"

    if failed:
        haystack = err + "\n" + out
        m = ANY_LIMIT.search(haystack) or (CLAUDE_LIMIT.search(haystack) if provider == "claude" else None)
        if m:
            return "limit", f"{provider} limit signature '{m.group(0)}' ({why})"
        return "incomplete", f"{provider} ended without a usable result ({why})"

    if provider == "claude" and len(result_text) < SHORT_RESULT:
        m = CLAUDE_LIMIT.search(result_text)
        if m:
            return "limit", f"claude limit signature '{m.group(0)}' in its result"
    return "ok", f"{provider} reported completion"


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--provider", required=True)
    p.add_argument("--exit", required=True, type=int)
    p.add_argument("--stdout", required=True)
    p.add_argument("--stderr")
    a = p.parse_args()
    verdict, reason = classify(a.provider, a.exit, read(a.stdout), read(a.stderr))
    print(f"{verdict}\t{' '.join(reason.split())}")


if __name__ == "__main__":
    main()
