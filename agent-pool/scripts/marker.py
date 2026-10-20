#!/usr/bin/env python3
"""marker.py: whether a resolve disposition marker settles the review it answers.

The markers themselves are read by skills/pr-loops-common/marker.py; this is the one place that
judges a parsed resolve marker, so prod-common.sh's verify (after a resolve run, and when it
derives a settled job) and the doctor's derive_job can never disagree about what is settled.

A resolve is accepted when it answers the latest review (reviewed == the review's head), accounts
for every finding (fixed + noted + deferred == the review's count), moved the head exactly when
it claims fixes (and then names the head it moved to, as a fast-forward), and deferred nothing.

Usage:
  marker.py check-resolve --review "<head> <findings>" --resolve "<head> <reviewed> <fixed> <deferred> [<noted>]"
                          --base SHA --head SHA [--fast-forward yes|no]

--review and --resolve take the output of `marker.py latest` and `marker.py resolve` as is.
--base is the head the review measured, --head the PR's head now; --fast-forward says whether
--head descends from --base (omit it when that cannot be checked). Prints "ok" or
"fail:<reason>" and exits 0 either way; 2 on bad arguments.
"""
import argparse
import sys

Review = tuple[str, int]
Resolve = tuple[str, str, int, int, int]


def parse_review(text: str) -> Review | None:
    fields = text.split()
    if len(fields) != 2:
        return None
    return fields[0], int(fields[1])


def parse_resolve(text: str) -> Resolve | None:
    fields = text.split()
    if len(fields) not in (4, 5):
        return None
    head, reviewed, fixed, deferred = fields[0], fields[1], int(fields[2]), int(fields[3])
    return head, reviewed, fixed, deferred, int(fields[4]) if len(fields) == 5 else 0


def check_resolve(review: Review | None, resolve: Resolve, base: str, head: str,
                  fast_forward: bool | None = None) -> str:
    """"ok", or "fail:<reason>" for the first check the resolve fails."""
    r_head, r_reviewed, fixed, deferred, noted = resolve
    review_head, review_count = review if review else ("", 0)
    if r_reviewed != review_head:
        return (f"fail:the resolver answered a review of {r_reviewed} but the findings on this PR are "
                f"from {review_head}")
    if fixed + noted + deferred != review_count:
        return (f"fail:the review raised {review_count} finding(s) but the resolver accounted for "
                f"{fixed + noted + deferred}")
    if fixed > 0:
        if head == base:
            return f"fail:the resolver claims {fixed} fix(es) but the PR head never moved"
        if r_head != head:
            return f"fail:the resolver named head {r_head} but the PR is at {head}"
        if fast_forward is False:
            return f"fail:the PR head moved to {head} but not as a fast-forward of {base}"
    elif head != base:
        return f"fail:the resolver claims no fixes yet the PR head moved to {head}"
    if deferred > 0:
        return (f"fail:{deferred} of {review_count} finding(s) are blocking and need a human decision; "
                f"{fixed} fixed, {noted} noted")
    return "ok"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    check = sub.add_parser("check-resolve")
    check.add_argument("--review", default="")
    check.add_argument("--resolve", required=True)
    check.add_argument("--base", required=True)
    check.add_argument("--head", required=True)
    check.add_argument("--fast-forward", choices=("yes", "no"))
    a = ap.parse_args()
    try:
        review = parse_review(a.review)
        resolve = parse_resolve(a.resolve)
    except ValueError:
        ap.error("--review and --resolve take integer counts")
    if resolve is None:
        ap.error("--resolve must be '<head> <reviewed> <fixed> <deferred> [<noted>]'")
    ff = None if a.fast_forward is None else a.fast_forward == "yes"
    print(check_resolve(review, resolve, a.base, a.head, ff))
    return 0


if __name__ == "__main__":
    sys.exit(main())
