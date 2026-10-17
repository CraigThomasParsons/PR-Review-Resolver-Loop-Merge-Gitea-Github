#!/usr/bin/env python3
"""report.py: check a worker's report before the controller publishes it.

Usage:
  report.py review  --marker-module F --file R --sha S
  report.py resolve --marker-module F --file R --review-head H --findings N

Prints "ok<TAB><head><TAB><fixed>" when the report carries a marker the loop can verify
(review: a pulse-review marker naming S; resolve: a pulse-resolve marker whose reviewed= is H,
with <head> the head it claims). Prints "nomarker<TAB><reason>" when there is no such marker
and "invalid<TAB><reason>" when a resolve marker does not account for exactly N findings, so
the controller refuses it before pushing anything. The marker grammar comes from
skills/pr-loops-common/marker.py so there is one parser.
"""
import argparse
import importlib.util


def load_marker(path):
    spec = importlib.util.spec_from_file_location("marker", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    p = argparse.ArgumentParser()
    p.add_argument("job", choices=["review", "resolve"])
    p.add_argument("--marker-module", required=True)
    p.add_argument("--file", required=True)
    p.add_argument("--sha", default="")
    p.add_argument("--review-head", default="")
    p.add_argument("--findings", type=int)
    a = p.parse_args()
    marker = load_marker(a.marker_module)
    try:
        body = open(a.file, errors="replace").read()
    except OSError:
        body = ""
    if not body.strip():
        print("nomarker\tthe worker left no report")
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
    main()
