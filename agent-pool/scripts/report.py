#!/usr/bin/env python3
"""report.py: check a worker's report before the controller publishes it.

Usage:
  report.py review  --marker-module F --file R --sha S
  report.py resolve --marker-module F --file R --review-head H --findings N
  report.py scan    --file F      exit 1 ("leak") if F holds a credential; the controller runs it
                                  over the commit messages and added lines it is about to push

Prints "ok<TAB><head><TAB><fixed>" when the report carries a marker the loop can verify
(review: a pulse-review marker naming S; resolve: a pulse-resolve marker whose reviewed= is H,
with <head> the head it claims). Prints "nomarker<TAB><reason>" when there is no such marker
and "invalid<TAB><reason>" when a resolve marker does not account for exactly N findings, so
the controller refuses it before pushing anything. A report that contains the adapter's token or
anything token-shaped is "invalid" too: it would be posted as a PR comment. The marker grammar
comes from skills/pr-loops-common/marker.py so there is one parser.
"""
import argparse
import importlib.util
import os
import re
import sys
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


def live_tokens():
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


def leaks_secret(body):
    return bool(TOKEN_SHAPES.search(body)) or any(t in body for t in live_tokens())


def load_marker(path):
    spec = importlib.util.spec_from_file_location("marker", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    p = argparse.ArgumentParser()
    p.add_argument("job", choices=["review", "resolve", "scan"])
    p.add_argument("--marker-module")
    p.add_argument("--file", required=True)
    p.add_argument("--sha", default="")
    p.add_argument("--review-head", default="")
    p.add_argument("--findings", type=int)
    a = p.parse_args()
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
    parsed = marker.parse_resolve(body)
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
