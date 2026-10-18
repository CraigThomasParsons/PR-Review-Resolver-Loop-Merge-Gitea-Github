#!/usr/bin/env python3
"""gitea-labels.py — roll the review:* label set out across Gitea repositories.

The PR review/resolve loops hand off through labels only, so every repo the loops
run against needs the same ten. Creating them by hand across 32 repos is exactly
the sort of thing that ends up half-done, so this does it idempotently: it reads
each repo's existing labels first and only creates what is missing.

Writes go through `tea labels create` (the chosen CLI); the read of existing labels
goes through the API, because tea's table output is for humans, not parsing.

DRY RUN BY DEFAULT. Pass --apply to actually create.

Usage:
  gitea-labels.py --all                      # every repo you can see
  gitea-labels.py --repo craigpars/AMPB ...  # named repos
  gitea-labels.py --all --apply
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

BASE = os.environ.get("GITEA_BASE_URL", "http://192.168.2.48:3000").rstrip("/") + "/api/v1"
TEA = os.environ.get("TEA_BIN", str(Path.home() / ".local/bin/tea"))
LOGIN = os.environ.get("TEA_LOGIN", "gitea-local")

# name -> (colour, description). Colours follow the handoff states:
# blue = queued, amber = a worker holds it, red = needs a human, green = done.
LABELS = {
    "review:requested":   ("1f77b4", "Queue this PR for an automated Claude review"),
    "review:in-progress": ("ff7f0e", "A review worker is running against this PR"),
    "review:findings":    ("d62728", "Automated review posted findings; queued for resolve"),
    "review:clean":       ("2ca02c", "Automated review found nothing"),
    "review:resolving":   ("ff7f0e", "A resolve worker is running against this PR"),
    "review:resolved":    ("2ca02c", "Findings fixed, gate passed, pushed fast-forward"),
    "review:automerge":   ("1f77b4", "Opt this PR into the mechanical merge tick"),
    "review:merging":     ("ff7f0e", "The mechanical merge tick has claimed this PR"),
    "review:merged":      ("2ca02c", "The mechanical merge tick merged this PR"),
    "review:needs-human": ("b10026", "Automation stopped and a person must look"),
    # agent-pool-core's own vocabulary (agent-pool/bin/prod-common.sh). Narrower than the
    # review:* set above -- derive_job() decides review vs. resolve vs. settled from markers,
    # not a separate label per stage. pr-merge.sh accepts agent:done the same way it accepts
    # review:clean/review:resolved.
    "agent:ready":        ("1f77b4", "Queued for the agent pool to claim"),
    "agent:claimed":      ("ff7f0e", "An agent-pool worker is running against this PR"),
    "agent:done":         ("2ca02c", "The agent pool finished; marker on the head names the result"),
    "agent:needs-human":  ("b10026", "The agent pool stopped and a person must look"),
}


def token():
    tok = os.environ.get("GITEA_TOKEN", "").strip()
    if tok:
        return tok
    f = Path.home() / ".config/pulse/gitea_token"
    if f.exists():
        return f.read_text().strip()
    raise SystemExit("gitea-labels: no token available")


def api(path, query=None):
    url = BASE + path + ("?" + urllib.parse.urlencode(query) if query else "")
    req = urllib.request.Request(url, headers={"Authorization": "token " + token()})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code} on {path}")


def all_repos():
    rows, page = [], 1
    while True:
        batch = api("/user/repos", {"limit": 50, "page": page})
        rows.extend(batch)
        if len(batch) < 50:
            return [r["full_name"] for r in rows if not r.get("archived")]
        page += 1
        if page > 100:
            raise SystemExit("gitea-labels: pagination runaway")


def existing(repo):
    try:
        return {l["name"] for l in api(f"/repos/{repo}/labels", {"limit": 100})}
    except RuntimeError as e:
        return None if "404" in str(e) else set()


def create(repo, name, colour, desc):
    p = subprocess.run(
        [TEA, "labels", "create", "--repo", repo, "--login", LOGIN,
         "--name", name, "--color", "#" + colour, "--description", desc],
        capture_output=True, text=True, timeout=60)
    return p.returncode, (p.stdout + p.stderr).strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--all", action="store_true", help="every non-archived repo you can see")
    ap.add_argument("--repo", action="append", default=[], help="repeatable owner/name")
    ap.add_argument("--apply", action="store_true", help="actually create (default: dry run)")
    a = ap.parse_args()

    repos = a.repo or (all_repos() if a.all else [])
    if not repos:
        raise SystemExit("gitea-labels: pass --all or --repo owner/name")

    mode = "APPLY" if a.apply else "DRY RUN (nothing will be written)"
    print(f"== {mode} — {len(repos)} repo(s), {len(LABELS)} labels ==\n")

    todo = created = failed = 0
    skipped_repos = []
    for repo in sorted(repos):
        have = existing(repo)
        if have is None:
            skipped_repos.append(repo)
            continue
        missing = [n for n in LABELS if n not in have]
        if not missing:
            print(f"  {repo:<48} already complete")
            continue
        todo += len(missing)
        print(f"  {repo:<48} missing {len(missing)}: {', '.join(s.split(':')[1] for s in missing)}")
        if a.apply:
            for n in missing:
                colour, desc = LABELS[n]
                rc, out = create(repo, n, colour, desc)
                if rc == 0:
                    created += 1
                else:
                    failed += 1
                    print(f"      FAILED {n}: {out[:120]}")

    print()
    if skipped_repos:
        print(f"  no label access (skipped): {', '.join(skipped_repos)}")
    if a.apply:
        print(f"  created {created}, failed {failed}")
        sys.exit(1 if failed else 0)
    else:
        print(f"  would create {todo} label(s). Re-run with --apply to do it.")


if __name__ == "__main__":
    main()
