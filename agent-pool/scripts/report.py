#!/usr/bin/env python3
"""report.py: check a worker's report before the controller publishes it.

Usage:
  report.py review  --marker-module F --file R --sha S
  report.py resolve --marker-module F --file R --review-head H --findings N
  report.py scan    --file F      exit 1 ("leak") if F holds a credential; the controller runs it
                                  over the commit message and added lines it is about to push
  report.py summary --file R --fallback TEXT
                                  print the report's `Summary: <subject>` line, the subject of
                                  the controller's commit, or TEXT when there is no usable one
  report.py stamp-head --file R --head NEWHEAD
                                  rewrite head=pending in R's resolve marker to head=NEWHEAD, in
                                  place; exit 1 if R has no pending resolve marker

Prints "ok<TAB><head><TAB><fixed>" when the report carries a marker the loop can verify
(review: a pulse-review marker naming S; resolve: a pulse-resolve marker whose reviewed= is H,
with <head> the head it claims). Prints "nomarker<TAB><reason>" when there is no such marker
and "invalid<TAB><reason>" when a resolve marker does not account for exactly N findings, so
the controller refuses it before pushing anything. A report that contains the adapter's token or
anything token-shaped is "invalid" too: it would be posted as a PR comment. The marker grammar
comes from skills/pr-loops-common/marker.py so there is one parser.

Workers never commit, so a resolve worker that changed files cannot know the head its work will
land at: its marker says head=pending, and <head> is printed as "pending". The controller makes
the commit (prod-common.sh controller_commit) and then stamps the real head into the report with
stamp-head before posting it, so every posted marker still carries a 40-hex head.
"""
import argparse
import importlib.util
import os
import re
import sys
import tempfile
import types
from pathlib import Path

# Bare 40-hex is deliberately absent: commit SHAs have the same shape. The live token is matched
# exactly instead.
TOKEN_SHAPES = re.compile(
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----"
    r"|\bgh[pousr]_[A-Za-z0-9]{30,}"
    r"|\bgithub_pat_[A-Za-z0-9_]{30,}"
    r"|\bsk-ant-[A-Za-z0-9_-]{20,}"
    r"|\bsk-[A-Za-z0-9]{32,}"
    r"|\bAKIA[0-9A-Z]{16}\b"
    r"|\bglpat-[A-Za-z0-9_-]{20,}"
    r"|\bxox[abprs]-[A-Za-z0-9-]{10,}"
    r"|\b(?:token|bearer)\s+[0-9a-f]{40}\b"
    # YAML, key=value and JSON credential lines: `token: 3f9a...`, GITEA_TOKEN="...", "password": "..."
    r"|\b[\w.-]*(?:token|secret|passw(?:or)?d|api[_-]?key|access[_-]?key|private[_-]?key)[\"']?"
    r"\s*[:=]\s*[\"']?(?=[A-Za-z_\-+/]*\d)[A-Za-z0-9+/_\-]{16,}",
    re.IGNORECASE)
RESOLVE_ENVELOPE = re.compile(r"<!--\s*pulse-resolve:v1\s+.*?-->", re.S)
PENDING = re.compile(r"(?<!\S)head=pending(?!\S)")
# Never a real SHA: marker.parse_resolve only reads 40-hex heads, so pending is parsed as this.
PENDING_STANDIN = "0" * 40
SUMMARY = re.compile(r"^Summary:[ \t]*(.+?)[ \t]*$", re.M)
SUMMARY_MAX = 100


def live_tokens() -> list[str]:
    found = []
    env = os.environ.get("GITEA_TOKEN", "").strip()
    if env:
        found.append(env)
    try:
        f = (Path.home() / ".config/pulse/gitea_token").read_text().strip()
        if f:
            found.append(f)
    except OSError:
        pass
    return [t for t in found if len(t) >= 8]


def leaks_secret(body: str) -> bool:
    return bool(TOKEN_SHAPES.search(body)) or any(t in body for t in live_tokens())


def load_marker(path: str) -> types.ModuleType:
    spec = importlib.util.spec_from_file_location("marker", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def with_pending(body: str, head: str) -> str:
    """body with head=pending inside every resolve marker replaced by head=<head>."""
    return RESOLVE_ENVELOPE.sub(lambda m: PENDING.sub("head=" + head, m.group(0)), body)


def parse_resolve(marker: types.ModuleType, body: str) -> tuple[str, str, int, int, int] | None:
    literal = marker.parse_resolve(body)
    if literal and literal[0] == PENDING_STANDIN:
        return None
    parsed = marker.parse_resolve(with_pending(body, PENDING_STANDIN))
    if parsed and parsed[0] == PENDING_STANDIN:
        return ("pending",) + tuple(parsed[1:])
    return parsed


def summary(body: str) -> str:
    """The first `Summary:` line, if it can be a commit subject: one printable line, no markup."""
    m = SUMMARY.search(body)
    if not m:
        return ""
    text = m.group(1)
    if len(text) > SUMMARY_MAX or not text.isprintable() or "<!--" in text or leaks_secret(text):
        return ""
    return text


def write_atomic(path: str, text: str) -> None:
    target = Path(path)
    descriptor, temporary = tempfile.mkstemp(dir=target.parent, prefix="." + target.name + ".")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", errors="surrogateescape") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def stamp_head(path: str, head: str) -> int:
    if not re.fullmatch(r"[0-9a-f]{40}", head):
        print(f"stamp-head: --head must be a 40-hex commit SHA, not {head!r}", file=sys.stderr)
        return 2
    try:
        body = Path(path).read_text(errors="surrogateescape")
    except OSError as error:
        print(f"stamp-head: cannot read {path}: {error.strerror}", file=sys.stderr)
        return 2
    if not any(PENDING.search(m.group(0)) for m in RESOLVE_ENVELOPE.finditer(body)):
        print("stamp-head: the report has no resolve marker with head=pending", file=sys.stderr)
        return 1
    write_atomic(path, with_pending(body, head))
    print(f"stamped\t{head}")
    return 0


def main() -> int | None:
    p = argparse.ArgumentParser()
    p.add_argument("job", choices=["review", "resolve", "scan", "summary", "stamp-head"])
    p.add_argument("--marker-module")
    p.add_argument("--file", required=True)
    p.add_argument("--sha", default="")
    p.add_argument("--review-head", default="")
    p.add_argument("--findings", type=int)
    p.add_argument("--head", default="")
    p.add_argument("--fallback", default="")
    a = p.parse_args()
    if a.job == "stamp-head":
        return stamp_head(a.file, a.head)
    try:
        body = open(a.file, errors="replace").read()
    except OSError:
        body = ""
    if a.job == "scan":
        if leaks_secret(body):
            print("leak\tcontains a credential or token-shaped string")
            return 1
        print("clean")
        return 0
    if a.job == "summary":
        print(summary(body) or a.fallback)
        return 0
    if not a.marker_module:
        p.error("--marker-module is required for review and resolve")
    marker = load_marker(a.marker_module)
    if not body.strip():
        print("nomarker\tthe worker left no report")
        return
    if leaks_secret(body):
        print("invalid\tthe report contains a credential or token-shaped string; refusing to post it")
        return
    if a.job == "review":
        found = marker.MARKER.findall(body)
        if not found or found[-1][0] != a.sha:
            print(f"nomarker\tthe report carries no review marker for {a.sha}")
            return
        print(f"ok\t{a.sha}\t0")
        return
    parsed = parse_resolve(marker, body)
    if not parsed:
        print("nomarker\tthe report carries no parseable resolve marker")
        return
    head, reviewed, fixed, deferred, noted = parsed
    if reviewed != a.review_head:
        print(f"nomarker\tthe resolve marker answers a review of {reviewed}, not {a.review_head}")
        return
    if a.findings is not None and fixed + noted + deferred != a.findings:
        print(f"invalid\tthe review raised {a.findings} finding(s) but the resolve marker accounts for "
              f"{fixed + noted + deferred}")
        return
    print(f"ok\t{head}\t{fixed}")


if __name__ == "__main__":
    sys.exit(main())
