#!/usr/bin/env python3
"""classify.py: read one headless provider run and say what kind of ending it was.

Usage: classify.py --provider P --exit RC --stdout FILE [--stderr FILE] [--result-out FILE]

Prints one line of tab-separated fields: verdict, reason, session id (may be empty).
  ok          the provider says it finished; verification decides whether it did the job
  setup       the pool's own setup got in the way: a tool call was denied or rejected, the
              binary is missing (127) or could not be executed (126, e.g. E2BIG), the model is
              unknown, the API key is invalid or the CLI wants a login. No cooldown; a person
              has to fix the configuration
  limit       a usage, credit or rate limit. The provider cools down and the job goes back
              to agent:ready (or to the next provider)
  timeout     the run hit WORKER_TIMEOUT (exit 124/137). Without a marker the job is requeued,
              never escalated to a human
  incomplete  the provider ended without a usable result and no limit signature explains it.
              Verification still runs; a fast run with no marker is then treated as a limit

--result-out receives the provider's final text (claude/cursor `result`, grok `text`, agy
`response`, codex stdout). The controller posts it as the report when the worker could not
write the report file itself (agy in plan mode).

Setup faults are found by JSON key, never by prose: cursor tool events carrying `rejected`
or `permissionDenied`, agy's `denied_actions`, claude's `permission_denials`. A run can exit
0 and report SUCCESS and still be a setup fault.

Order: exit 124/137 is a timeout before anything else is read. Setup signatures (SETUP) are
checked before limit signatures, so a login prompt or a bad model never reads as a limit.

Setup and limit signatures are read from the provider's own messages only when it reports
failure: stderr plus the final result (for cursor, result/error events and non-JSON lines,
never tool_call events, whose output is whatever the worker read). On a run that reports
success, only a short final result (under 400 characters, i.e. nothing but the product's own
message) is checked, for every provider, and only for wording a review would not use in
passing (RESULT_LIMIT, PRODUCT_LIMIT). A review that discusses rate limiting must not read as
a rate limit.
"""
import argparse
import json
import re
import sys

ANY_LIMIT = re.compile(
    r"\b429\b|too many requests|rate[ _-]?limit|quota[ _-]?exceeded|exceeded (?:your |the )?quota"
    r"|insufficient[ _-]?credits?|resource[ _-]?exhausted|usage[ _-]?limit|hit your .* limit", re.I)
# classify-pane.sh's PARKED product dialogs, plus the credit wall that started all this.
PRODUCT_LIMIT = re.compile(
    r"You've reached your .* limit|/usage-credits|Set up auto mode for your environment"
    r"|purchase more credits|upgrade your plan to continue|Credit balance is too low", re.I)
SETUP = re.compile(
    r"(?:unknown|invalid|unsupported) model|model[ _-]not[ _-]found|not_found_error"
    r"|invalid[ _-]?(?:x-)?api[ _-]?key|authentication_error|login required|not logged in"
    r"|Select login method|log in to continue|please (?:log|sign) in", re.I)
# On a run that reports success only wording a review would not use in passing counts: a bare
# "429" or "rate limit" in a final summary is usually about the code under review.
RESULT_LIMIT = re.compile(
    r"resource[ _-]?exhausted|usage[ _-]?limit|hit your .* limit|insufficient[ _-]?credits?"
    r"|too many requests", re.I)
DENIAL_KEYS = ("rejected", "permissionDenied", "denied_actions", "permission_denials")
SESSION_KEYS = ("conversation_id", "session_id", "sessionId")
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
        try:
            doc = json.loads(line.strip())
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


def session_of(docs):
    for doc in docs:
        for key in SESSION_KEYS:
            if doc.get(key):
                return str(doc[key])
    return ""


def describe(found):
    where, value = found[0]
    more = f" (+{len(found) - 1} more)" if len(found) > 1 else ""
    return f"{where}={json.dumps(value)[:160]}{more}"


def limit_in(text):
    return ANY_LIMIT.search(text) or PRODUCT_LIMIT.search(text)


def classify(provider, rc, out, err):
    """Return (verdict, reason, session, result_text)."""
    if rc == 127:
        return "setup", f"{provider} binary missing (exit 127)", "", ""
    if rc == 126:
        why = "argument list too long" if "argument list too long" in err.lower() else "permission or exec format"
        return "setup", f"{provider} could not be executed (exit 126: {why})", "", ""
    if rc in (124, 137):
        return "timeout", f"{provider} hit the worker timeout (exit {rc})", "", ""

    docs, failed, result_text, why, own = [], rc != 0, "", f"exit {rc}", out
    if provider == "cursor":
        docs = parse_events(out)
        own = "\n".join([json.dumps(e) for e in docs if e.get("type") in ("result", "error")]
                        + [line for line in out.splitlines() if not line.strip().startswith("{")])
        results = [e for e in docs if e.get("type") == "result"]
        if not results:
            failed, why = True, "no result event in the stream"
        else:
            last = results[-1]
            result_text = str(last.get("result", ""))
            if last.get("is_error") or last.get("subtype") not in (None, "success"):
                failed, why = True, f"result event subtype={last.get('subtype')} is_error={last.get('is_error')}"
    elif provider == "codex":
        result_text = out
    else:
        doc = parse_object(out)
        if doc is not None:
            docs = [doc]
        if doc is None:
            failed, why = True, "no JSON result"
        elif provider == "claude":
            result_text = str(doc.get("result", ""))
            if doc.get("is_error") or doc.get("subtype") not in (None, "success"):
                failed, why = True, f"subtype={doc.get('subtype')} is_error={doc.get('is_error')}"
        elif provider == "agy":
            result_text = str(doc.get("response") or doc.get("result") or doc.get("text") or "")
            if str(doc.get("status", "")).upper() != "SUCCESS":
                failed, why = True, f"status={doc.get('status')}"
        elif provider == "grok":
            result_text = str(doc.get("text", ""))
            if doc.get("error"):
                failed, why = True, f"error={str(doc.get('error'))[:120]}"
    session = session_of(docs)

    found = [d for doc in docs for d in denials(doc)]
    if found:
        return "setup", f"{provider} denied a tool call the worker needed: {describe(found)}", session, result_text

    if failed:
        text = err + "\n" + own
        m = SETUP.search(text)
        if m:
            return "setup", f"{provider} setup signature '{m.group(0)}' ({why})", session, result_text
        m = limit_in(text)
        if m:
            return "limit", f"{provider} limit signature '{m.group(0)}' ({why})", session, result_text
        return "incomplete", f"{provider} ended without a usable result ({why})", session, result_text

    if len(result_text.strip()) < SHORT_RESULT:
        m = SETUP.search(result_text)
        if m:
            return "setup", f"{provider} setup signature '{m.group(0)}' in its short result", session, result_text
        m = RESULT_LIMIT.search(result_text) or PRODUCT_LIMIT.search(result_text)
        if m:
            return "limit", f"{provider} limit signature '{m.group(0)}' in its short result", session, result_text
    return "ok", f"{provider} reported completion", session, result_text


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--provider", required=True)
    p.add_argument("--exit", required=True, type=int)
    p.add_argument("--stdout", required=True)
    p.add_argument("--stderr")
    p.add_argument("--result-out")
    a = p.parse_args()
    verdict, reason, session, result_text = classify(a.provider, a.exit, read(a.stdout), read(a.stderr))
    if a.result_out:
        with open(a.result_out, "w") as f:
            f.write(result_text)
    print(f"{verdict}\t{' '.join(reason.split())}\t{session}")


if __name__ == "__main__":
    main()
