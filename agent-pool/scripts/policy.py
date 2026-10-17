#!/usr/bin/env python3
"""policy.py: the one worker permission policy, translated per provider CLI.

Workers never publish. They read, edit and commit locally (resolve), or only read (review),
and write a report file. The controller does every push and comment through the claim guard,
so the policy denies all of `git push` and every gitea-pr.py write to every worker.

The policy is an allowlist: nothing runs unless listed. Shell allow entries are specific
read commands, the Gitea adapter's three read subcommands at its absolute path, and named
gate/test commands. There is no `python3 *`, `node *`, `npx *` or broad `git`.

Deny entries back the allowlist up and never rely on an absolute path alone (a relative
`gitea-pr.py comment` is denied by a leading-glob rule). The explicit denies for
`git push --force`, `git reset --hard` and `git merge` stay in every provider's policy.

Rule syntax per provider:
  claude  Bash(<glob>) in --allowedTools / --disallowedTools; Read Grep Glob Write Edit tools
  grok    --allow/--deny Bash(<glob>), Read, Grep, Write(<path glob>), Edit(<path glob>)
  cursor  .cursor/cli.json Shell(<command prefix>), Read(**), Write(<glob>); prefix rules
          cannot express a leading glob, so cursor's denies are spelled out and its safety
          rests on the allowlist (cursor-agent runs without --force)

Usage:
  policy.py rules  --provider P --job review|resolve --adapter F --worktree D --report R
                   prints "allow<TAB>rule" / "deny<TAB>rule" lines in that provider's syntax
  policy.py cursor-json  (same options)                   prints .cursor/cli.json
  policy.py check  --family glob|prefix --job J --adapter F --worktree D --report R -- COMMAND
                   prints allow or deny for one shell command, emulating the provider's
                   matching (glob for claude/grok, prefix for cursor); every part of a compound
                   command (&&, ||, ;, |) must be allowed
"""
import argparse
import fnmatch
import json
import re
import sys

READ_SHELL = ["git log*", "git diff*", "git show*", "git status*", "git rev-parse*", "git ls-files*",
              "git grep *", "git blame *", "cat *", "ls", "ls *", "head *", "tail *", "wc *", "grep *", "rg *"]
GATE_SHELL = ["npm run *", "npm test", "npm test *", "dotnet build", "dotnet build *", "dotnet test",
              "dotnet test *", "just *", "composer test*", "composer lint*", "php artisan test*",
              "vendor/bin/pint*", "vendor/bin/phpunit*", "./vendor/bin/pint*", "./vendor/bin/phpunit*"]
COMMIT_SHELL = ["git add *", "git commit -m *", "git commit -F *"]
DENY_SHELL = [
    "git push*", "*git push*", "git push --force*", "git reset --hard*", "git merge*", "git rebase*",
    "git branch -D*", "git config*", "git -C*", "git -c*", "git remote*", "git update-ref*",
    "git add -A*", "git add --all*", "git add -u*", "git add .", "git add . *", "git add :/*",
    "git commit -a*", "git commit --all*", "git commit --amend*", "git commit * -a*", "git commit * --all*",
    "git commit * --amend*", "*gitea-pr.py comment*", "*gitea-pr.py label*", "*gitea-pr.py merge*",
    "tea", "tea *", "gh", "gh *", "curl*", "wget*", "sudo*", "rm -rf*", "rm -fr*", "systemctl*", "crontab*",
    "python3 -c*", "python3 -", "python3 - *", "node*", "npx*", "bash*", "sh *", "env *", "eval *",
    "*$(*", "*`*", "*<(*", "rg *--pre*", "git grep *-O*", "git grep *--open-files-in-pager*",
    "git * --ext-diff*", "git diff* --output*",
]
REVIEW_DENY_SHELL = ["git add*", "git commit*"]
CURSOR_DENY = ["git push", "git push --force", "git reset --hard", "git merge", "git rebase", "git branch -D",
               "git config", "git -C", "git -c", "git remote", "git update-ref", "git add -A", "git add --all",
               "git add -u", "git add .", "git commit -a", "git commit --all", "git commit --amend",
               "tea", "gh", "curl", "wget", "sudo", "rm -rf", "rm -fr", "systemctl", "crontab",
               "python3 -c", "python3 -", "node", "npx", "bash", "sh", "env", "eval",
               "rg --pre", "git grep -O", "git grep --open-files-in-pager"]
CURSOR_REVIEW_DENY = ["git add", "git commit"]
SPLIT = re.compile(r"\s*(?:&&|\|\||;|\||\n)\s*")


def shell_rules(a):
    allow = list(READ_SHELL) + [f"python3 {a.adapter} {sub} *" for sub in ("head", "comments", "threads")]
    deny = list(DENY_SHELL)
    if a.job == "resolve":
        allow += COMMIT_SHELL + GATE_SHELL
    else:
        deny += REVIEW_DENY_SHELL
    return allow, deny


def rules(a):
    allow, deny = shell_rules(a)
    if a.provider == "claude":
        tools = ["Read", "Grep", "Glob", "Write"] + (["Edit", "MultiEdit"] if a.job == "resolve" else [])
        return tools + [f"Bash({r})" for r in allow], [f"Bash({r})" for r in deny]
    if a.provider == "grok":
        tools = ["Read", "Grep", f"Write({a.report})"]
        if a.job == "resolve":
            tools += [f"Edit({a.worktree}/**)", f"Write({a.worktree}/**)"]
        return tools + [f"Bash({r})" for r in allow], [f"Bash({r})" for r in deny]
    if a.provider == "cursor":
        prefixes = [r.rstrip("*").rstrip() for r in allow]
        allow_rules = ["Read(**)", f"Write({a.report})"] + (["Write(**)"] if a.job == "resolve" else [])
        deny_rules = CURSOR_DENY + (CURSOR_REVIEW_DENY if a.job == "review" else [])
        deny_rules += [f"python3 {a.adapter} {sub}" for sub in ("comment", "label", "merge")]
        return (allow_rules + [f"Shell({p})" for p in dict.fromkeys(prefixes)],
                [f"Shell({p})" for p in deny_rules])
    raise SystemExit(f"policy: no rule translation for provider {a.provider}")


def prefix_match(command, prefix):
    return command == prefix or command.startswith(prefix + " ")


def check(a):
    allow, deny = shell_rules(a)
    if a.family == "prefix":
        allow = [r.rstrip("*").rstrip() for r in allow]
        deny = CURSOR_DENY + (CURSOR_REVIEW_DENY if a.job == "review" else []) \
            + [f"python3 {a.adapter} {sub}" for sub in ("comment", "label", "merge")]
        allowed = lambda c: any(prefix_match(c, p) for p in allow)
        denied = lambda c: any(prefix_match(c, p) for p in deny)
    else:
        allowed = lambda c: any(fnmatch.fnmatchcase(c, p) for p in allow)
        denied = lambda c: any(fnmatch.fnmatchcase(c, p) for p in deny)
    for part in (p.strip() for p in SPLIT.split(" ".join(a.command).strip())):
        if not part:
            continue
        if denied(part) or not allowed(part):
            return "deny"
    return "allow"


def main():
    argv = sys.argv[1:]
    command = []
    if "--" in argv:
        split = argv.index("--")
        argv, command = argv[:split], argv[split + 1:]
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("action", choices=["rules", "cursor-json", "check"])
    p.add_argument("--provider", default="")
    p.add_argument("--family", choices=["glob", "prefix"], default="glob")
    p.add_argument("--job", choices=["review", "resolve"], required=True)
    p.add_argument("--adapter", required=True)
    p.add_argument("--worktree", default="")
    p.add_argument("--report", default="")
    a = p.parse_args(argv)
    a.command = command
    if a.action == "check":
        print(check(a))
        return 0
    if a.action == "cursor-json":
        a.provider = "cursor"
    allow, deny = rules(a)
    if a.action == "cursor-json":
        print(json.dumps({"permissions": {"allow": allow, "deny": deny}}, indent=2))
        return 0
    for r in allow:
        print(f"allow\t{r}")
    for r in deny:
        print(f"deny\t{r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
