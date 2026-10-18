#!/usr/bin/env python3
"""gitea-pr.py — the Gitea adapter for the PR review/resolve/merge loops.

The upstream loops are built on `gh` against GitHub. AMPB and the other 31 repos
live on self-hosted Gitea, so every `gh` call needs an equivalent. This is it.

It is deliberately HYBRID, and the reason matters:

  * WRITES go through `tea` (the user's chosen CLI): label create, add/remove
    labels, add comment. tea is good at these and keeps one credential store.
  * READS go through the Gitea REST API directly, because `tea pr list --output
    json` returns only {author,index,labels,milestone,state,title,updated}. It
    omits `draft` and — critically — the HEAD SHA. The whole safety model of the
    loops is "no label moves on a worker's say-so; each move is gated on a marker
    verified against the PR's current head". You cannot build that on tea's JSON.

Merge is exposed only as the explicit ``merge`` subcommand. Review and resolve
workers deny that command; the deterministic merge tick is its sole caller.

Subcommands:
  list   --repo O/R [--state open]   PRs as JSON with number, draft, labels,
                                     head_sha, author, is_bot, assignees
  head   --repo O/R --pr N           print the current head SHA (the gate)
  labels --repo O/R --pr N           the PR's current label names as JSON (read live)
  state  --repo O/R --pr N           {head_sha, labels, assignees} from one live read
  label  --repo O/R --pr N [--add L] [--remove L]
  comment --repo O/R --pr N --body-file F
  comments --repo O/R --pr N         existing comments as JSON (marker lookup)
  threads --repo O/R --pr N          unresolved inline review comments as JSON
  diff   --repo O/R --pr N           unified diff
  merge  --repo O/R --pr N --expected-head SHA --base REF [--style STYLE]
                                     precheck the live PR, then merge via tea

Auth: GITEA_TOKEN, else ~/.config/pulse/gitea_token. The token is never passed in
argv; tea reads its own config, the API calls use a header.
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


def token():
    tok = os.environ.get("GITEA_TOKEN", "").strip()
    if tok:
        return tok
    f = Path.home() / ".config/pulse/gitea_token"
    if f.exists():
        return f.read_text().strip()
    raise SystemExit("gitea-pr: no token in GITEA_TOKEN or ~/.config/pulse/gitea_token")


def api(path, query=None):
    url = BASE + path + ("?" + urllib.parse.urlencode(query) if query else "")
    req = urllib.request.Request(url, headers={"Authorization": "token " + token()})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        raise SystemExit(f"gitea-pr: HTTP {e.code} on {path}")


def api_text(path):
    url = BASE + path
    req = urllib.request.Request(url, headers={"Authorization": "token " + token()})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        raise SystemExit(f"gitea-pr: HTTP {e.code} on {path}")


def tea_run(args):
    """Run tea for a mutation. Returns (rc, output)."""
    cmd = [TEA] + args + ["--login", LOGIN]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    return p.returncode, (p.stdout + p.stderr).strip()


def cmd_list(a):
    rows, page = [], 1
    while True:
        batch = api(f"/repos/{a.repo}/pulls", {"state": a.state, "limit": 50, "page": page})
        if not isinstance(batch, list):
            raise SystemExit("gitea-pr: expected a PR list")
        rows.extend(batch)
        if len(batch) < 50:
            break
        page += 1
        if page > 200:
            raise SystemExit("gitea-pr: pagination runaway; refusing partial discovery")
    out = []
    for p in rows:
        user = p.get("user") or {}
        login = user.get("login", "")
        out.append({
            "number": p.get("number"),
            "title": p.get("title", ""),
            # draft and head_sha are the two fields tea's JSON does not give us,
            # and both gate the loop: drafts are skipped, head_sha verifies markers.
            "draft": bool(p.get("draft")),
            "head_sha": ((p.get("head") or {}).get("sha") or ""),
            "head_ref": ((p.get("head") or {}).get("ref") or ""),
            "base_ref": ((p.get("base") or {}).get("ref") or ""),
            "author": login,
            # Gitea has no is_bot flag; treat the known automation identities as bots.
            "is_bot": login.lower() in {"gitea-actions", "actions-user"} or login.endswith("[bot]"),
            "labels": [l.get("name") for l in (p.get("labels") or [])],
            # The agent pool reads a non-bot assignee as a human hold.
            "assignees": [u.get("login") for u in (p.get("assignees") or []) if u.get("login")],
            "url": p.get("html_url", ""),
        })
    print(json.dumps(out, indent=2))


def cmd_head(a):
    p = api(f"/repos/{a.repo}/pulls/{a.pr}")
    sha = ((p.get("head") or {}).get("sha") or "")
    if not sha:
        raise SystemExit(f"gitea-pr: no head sha for {a.repo}#{a.pr}")
    print(sha)


def cmd_labels(a):
    print(json.dumps([l.get("name") for l in api(f"/repos/{a.repo}/issues/{a.pr}/labels")]))


def cmd_state(a):
    p = api(f"/repos/{a.repo}/pulls/{a.pr}")
    print(json.dumps({"head_sha": ((p.get("head") or {}).get("sha") or ""),
                      "labels": [l.get("name") for l in (p.get("labels") or [])],
                      "assignees": [u.get("login") for u in (p.get("assignees") or []) if u.get("login")]}))


def cmd_label(a):
    if not a.add and not a.remove:
        raise SystemExit("gitea-pr: label needs --add and/or --remove")
    args = ["pr", "edit", str(a.pr), "--repo", a.repo]
    if a.add:
        args += ["--add-labels", a.add]
    if a.remove:
        args += ["--remove-labels", a.remove]
    rc, out = tea_run(args)
    if rc != 0:
        raise SystemExit(f"gitea-pr: tea pr edit failed: {out}")
    print(f"ok: #{a.pr} +[{a.add or ''}] -[{a.remove or ''}]")


def cmd_comment(a):
    body = Path(a.body_file).read_text()
    if not body.strip():
        raise SystemExit("gitea-pr: refusing to post an empty comment")
    # tea comments add takes the body as an argument; pass via stdin-free argv is
    # unavoidable here, but the body is not a secret.
    rc, out = tea_run(["comments", "add", f"{a.pr}", body, "--repo", a.repo])
    if rc != 0:
        raise SystemExit(f"gitea-pr: tea comments add failed: {out}")
    print(f"ok: commented on #{a.pr}")


def cmd_comments(a):
    rows = api(f"/repos/{a.repo}/issues/{a.pr}/comments")
    print(json.dumps([{"id": c.get("id"),
                       "user": (c.get("user") or {}).get("login"),
                       "created_at": c.get("created_at"),
                       "body": c.get("body", "")} for c in rows], indent=2))


def cmd_threads(a):
    # Inline review comments that nobody has marked resolved. Gitea has no thread object, so
    # each unresolved review comment stands for one thread; replies share its path and line.
    out = []
    for r in api(f"/repos/{a.repo}/pulls/{a.pr}/reviews"):
        for c in api(f"/repos/{a.repo}/pulls/{a.pr}/reviews/{r.get('id')}/comments"):
            if c.get("resolver"):
                continue
            out.append({"id": c.get("id"),
                        "review_id": r.get("id"),
                        "user": (c.get("user") or {}).get("login"),
                        "path": c.get("path"),
                        "line": c.get("position") or c.get("original_position"),
                        "body": c.get("body", "")})
    print(json.dumps(out, indent=2))


def cmd_diff(a):
    print(api_text(f"/repos/{a.repo}/pulls/{a.pr}.diff"))


def cmd_merge(a):
    """Fail closed on live PR state, then invoke tea's explicit merge command."""
    p = api(f"/repos/{a.repo}/pulls/{a.pr}")
    head = ((p.get("head") or {}).get("sha") or "")
    base = ((p.get("base") or {}).get("ref") or "")
    if p.get("state") != "open":
        raise SystemExit(f"gitea-pr: #{a.pr} is not open")
    if bool(p.get("draft")):
        raise SystemExit(f"gitea-pr: #{a.pr} is a draft")
    if head != a.expected_head:
        raise SystemExit(
            f"gitea-pr: #{a.pr} head moved: expected {a.expected_head}, found {head or 'none'}"
        )
    if base != a.base:
        raise SystemExit(
            f"gitea-pr: #{a.pr} base is {base or 'unknown'}, expected {a.base}"
        )
    if p.get("mergeable") is not True:
        raise SystemExit(f"gitea-pr: #{a.pr} is not mergeable")

    rc, out = tea_run([
        "pr", "merge", str(a.pr), "--repo", a.repo, "--style", a.style
    ])
    if rc != 0:
        raise SystemExit(f"gitea-pr: tea pr merge failed: {out}")
    print(f"ok: merged #{a.pr} at {head} with style {a.style}")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    def add(name, fn, pr=True):
        s = sub.add_parser(name)
        s.add_argument("--repo", required=True)
        if pr:
            s.add_argument("--pr", required=True, type=int)
        s.set_defaults(fn=fn)
        return s

    s = sub.add_parser("list"); s.add_argument("--repo", required=True)
    s.add_argument("--state", default="open", choices=["open", "closed", "all"])
    s.set_defaults(fn=cmd_list)

    add("head", cmd_head)
    add("labels", cmd_labels)
    add("state", cmd_state)
    s = add("label", cmd_label); s.add_argument("--add"); s.add_argument("--remove")
    s = add("comment", cmd_comment); s.add_argument("--body-file", required=True)
    add("comments", cmd_comments)
    add("threads", cmd_threads)
    add("diff", cmd_diff)
    s = add("merge", cmd_merge)
    s.add_argument("--expected-head", required=True)
    s.add_argument("--base", required=True)
    s.add_argument("--style", default="merge",
                   choices=["merge", "rebase", "squash", "rebase-merge"])

    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
