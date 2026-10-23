#!/usr/bin/env python3
"""provider-fallback.py: the PR loop's memory of a provider's usage limit, and its reader of an
Agy review run.

Usage:
  provider-fallback.py limit-record --state DIR --provider P --text-file F [--default-secs N] [--now EPOCH]
      Parse the limit's reset time out of F (the provider's own message, e.g. a captured pane) and
      write DIR/provider-limits/P.json. Prints "<until-epoch>\t<until-iso>\t<parsed|default>".
  provider-fallback.py limit-check --state DIR --provider P [--now EPOCH]
      Exit 0 and print "<until-epoch>\t<until-iso>\t<reason>" while the limit stands; exit 1 when
      there is none, it has expired (the file is removed) or it cannot be read.
  provider-fallback.py agy-result --rc N --stdout F --stderr F --sha SHA --report-out F
      Read one `agy -p ... --output-format json` run. Prints "ok\t<findings>" and writes Agy's
      response to --report-out when it carries the review marker for SHA; otherwise prints
      "fail\t<reason>" where the reason quotes Agy's own error text.

The reset is read from wording like "resets Oct 24, 5am (America/Toronto)", "resets 11pm",
"resets in 3h 20m" or the older "usage limit reached|1761300000". Anything unparseable, in the
past or more than eight days out falls back to --default-secs (six hours by default).
"""
import argparse
import json
import os
import re
import sys
import tempfile
import time
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

DEFAULT_SECS = 6 * 3600
MAX_AHEAD = 8 * 86400
MONTHS = {m: i for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"], start=1)}

EPOCH = re.compile(r"limit reached\|(\d{10})\b", re.I)
AT = re.compile(
    r"resets?\s+(?:at\s+|on\s+)?"
    r"(?:(?P<mon>jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(?P<day>\d{1,2})(?:st|nd|rd|th)?,?\s*(?:at\s+)?)?"
    r"(?P<h>\d{1,2})(?::(?P<m>\d{2}))?\s*(?P<ap>am|pm)?"
    r"(?:\s*\((?P<tz>[A-Za-z_]+(?:/[A-Za-z0-9_+-]+)*)\))?", re.I)
IN = re.compile(r"resets?\s+in\s+(?:(?P<d>\d+)\s*d(?:ays?)?\s*)?(?:(?P<h>\d+)\s*h(?:ours?|rs?)?\s*)?"
                r"(?:(?P<m>\d+)\s*m(?:in(?:ute)?s?)?)?", re.I)
REVIEW_MARKER = r"<!--\s*pulse-review:v1\s+head={sha}\s+findings=(\d+)\s*-->"
EXCERPT = 600


def zone(name: str | None):
    if name:
        try:
            return ZoneInfo(name)
        except (ZoneInfoNotFoundError, ValueError):
            pass
    return datetime.now().astimezone().tzinfo


def at_match(m: re.Match[str], now: float) -> float | None:
    if not m.group("ap") and not m.group("m"):
        return None  # a bare "resets 3" is not a time
    hour, minute = int(m.group("h")), int(m.group("m") or 0)
    ap = (m.group("ap") or "").lower()
    if ap:
        if not 1 <= hour <= 12:
            return None
        hour = hour % 12 + (12 if ap == "pm" else 0)
    if hour > 23 or minute > 59:
        return None
    tz = zone(m.group("tz"))
    here = datetime.fromtimestamp(now, tz)
    if m.group("mon"):
        try:
            when = here.replace(month=MONTHS[m.group("mon").lower()[:3]], day=int(m.group("day")),
                                hour=hour, minute=minute, second=0, microsecond=0)
        except ValueError:
            return None
        if when.timestamp() < now - 86400:
            when = when.replace(year=when.year + 1)
    else:
        when = here.replace(hour=hour, minute=minute, second=0, microsecond=0)
        if when.timestamp() <= now:
            when += timedelta(days=1)
    return when.timestamp()


def parse_reset(text: str, now: float) -> float | None:
    """The reset named by the LAST limit message in text, or None."""
    found: list[tuple[int, float | None]] = []
    found += [(m.start(), float(m.group(1))) for m in EPOCH.finditer(text)]
    found += [(m.start(), at_match(m, now)) for m in AT.finditer(text)]
    for m in IN.finditer(text):
        d, h, mi = (int(m.group(k) or 0) for k in ("d", "h", "m"))
        if d or h or mi:
            found.append((m.start(), now + d * 86400 + h * 3600 + mi * 60))
    for _, until in sorted(found, reverse=True):
        if until is not None and now < until <= now + MAX_AHEAD:
            return until
    return None


def limit_file(state: str, provider: str) -> str:
    return os.path.join(state, "provider-limits", f"{provider}.json")


def write_atomic(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".fallback.", dir=os.path.dirname(os.path.abspath(path)))
    try:
        with os.fdopen(fd, "w") as out:
            out.write(text)
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def iso(epoch: float) -> str:
    return datetime.fromtimestamp(epoch).astimezone().isoformat(timespec="minutes")


def one_line(text: str, limit: int = EXCERPT) -> str:
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 3] + "..."


def read(path: str) -> str:
    try:
        with open(path, errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def cmd_limit_record(a: argparse.Namespace) -> None:
    now = a.now if a.now is not None else time.time()
    text = read(a.text_file)
    until = parse_reset(text, now)
    source = "parsed" if until is not None else "default"
    if until is None:
        until = now + a.default_secs
    reason = next((one_line(line, 300) for line in reversed(text.splitlines())
                   if re.search(r"limit|429|too many requests", line, re.I)), "usage limit")
    write_atomic(limit_file(a.state, a.provider), json.dumps({
        "provider": a.provider, "until": int(until), "until_iso": iso(until), "source": source,
        "reason": reason, "recorded_at": int(now)}, indent=2) + "\n")
    print(f"{int(until)}\t{iso(until)}\t{source}")


def cmd_limit_check(a: argparse.Namespace) -> None:
    now = a.now if a.now is not None else time.time()
    path = limit_file(a.state, a.provider)
    try:
        with open(path) as f:
            doc = json.load(f)
        until = int(doc["until"])
    except (OSError, ValueError, KeyError, TypeError):
        sys.exit(1)
    if until <= now:
        try:
            os.unlink(path)
        except OSError:
            pass
        sys.exit(1)
    print(f"{until}\t{doc.get('until_iso') or iso(until)}\t{doc.get('reason', '')}")


def cmd_agy_result(a: argparse.Namespace) -> None:
    out, err = read(a.stdout), read(a.stderr)
    doc = None
    for candidate in [out] + list(reversed(out.strip().splitlines())):
        try:
            parsed = json.loads(candidate)
        except ValueError:
            continue
        if isinstance(parsed, dict):
            doc = parsed
            break
    if a.rc in (124, 137):
        print(f"fail\tagy hit the worker timeout (exit {a.rc}): {one_line(err or out) or 'no output'}")
        return
    if doc is None:
        print(f"fail\tagy exited {a.rc} without a JSON result: {one_line(err or out) or 'no output'}")
        return
    response = str(doc.get("response") or doc.get("result") or doc.get("text") or "")
    status = str(doc.get("status", ""))
    if a.rc != 0 or status.upper() != "SUCCESS":
        said = doc.get("error") or doc.get("message") or response or err
        print(f"fail\tagy exited {a.rc} with status={status or 'none'}: {one_line(str(said)) or 'no error text'}")
        return
    m = re.search(REVIEW_MARKER.format(sha=re.escape(a.sha)), response)
    if not m:
        print(f"fail\tagy finished but its response carries no review marker for {a.sha}: "
              f"{one_line(response) or 'empty response'}")
        return
    write_atomic(a.report_out, response.rstrip() + "\n")
    print(f"ok\t{m.group(1)}")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("limit-record")
    r.add_argument("--state", required=True)
    r.add_argument("--provider", required=True)
    r.add_argument("--text-file", required=True)
    r.add_argument("--default-secs", type=int, default=DEFAULT_SECS)
    r.add_argument("--now", type=float)
    c = sub.add_parser("limit-check")
    c.add_argument("--state", required=True)
    c.add_argument("--provider", required=True)
    c.add_argument("--now", type=float)
    g = sub.add_parser("agy-result")
    g.add_argument("--rc", type=int, required=True)
    g.add_argument("--stdout", required=True)
    g.add_argument("--stderr", required=True)
    g.add_argument("--sha", required=True)
    g.add_argument("--report-out", required=True)
    a = p.parse_args()
    {"limit-record": cmd_limit_record, "limit-check": cmd_limit_check, "agy-result": cmd_agy_result}[a.cmd](a)


if __name__ == "__main__":
    main()
