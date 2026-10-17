#!/usr/bin/env python3
"""policy.py: the one worker permission policy, translated per provider CLI.

Workers never publish. They read, edit and commit locally (resolve), or only read (review),
and write a report file. The controller does every push and comment through the claim guard,
so the policy denies all of `git push` and every gitea-pr.py write to every worker.

The policy is deny-by-default at the ARGUMENT level (`check`). An unquoted `{` or `}` anywhere
denies the whole command before anything else is read: bash brace expansion would otherwise
turn `rg {-,}-pre=sh` into `rg --pre=sh`. A command line is then tokenized like a shell would
(quotes respected); `&&`, `||`, `;`, `|` and newlines separate commands; any redirection (`>`,
`>>`, `<`, `2>`, `&>`, `>&` ...), background `&`, subshell `(`, `$` or backtick is its own
denied segment. Every remaining command must be one of:

  git diff|log|show|status|rev-parse|ls-files|grep|blame  with vetted options only (no
        difftool, no --output, no --ext-diff/--textconv, no global options such as -C/-c)
  cat ls head tail wc grep rg                              with vetted options only
  python3 <adapter> head|comments|threads --repo R --pr N  the adapter's reads, absolute path
  git add <named paths> / git commit -m                    resolve only; no -A/-u/-f/., no
        tool configuration paths, no --amend/-a, no -F (a file would become the message)
  the named gate commands                                  resolve only (their arguments are
        not vetted; the controller will run gates itself from a pinned list, see D1)

Paths are normalised (~ expanded, //, /./ and .. collapsed, symlinks resolved) before they are
checked. Every path a reader or git is given must stay inside the worktree or the runs folder;
a wildcard is expanded and every match must stay inside the worktree. Option values and gate
arguments may not name a credential path (~/.ssh, ~/.config/tea, ~/.config/pulse, ~/.netrc,
~/.git-credentials, /proc ...).

The emitted rules follow the same policy as far as each CLI's syntax allows:
  claude  Bash(<glob>) allow/deny per subcommand ("git diff" and "git diff *"), plus denies
          for git difftool*, *--output*, *>*, *<*; Read/Write/Edit scoped with // absolute
          paths. Claude also gets a PreToolUse hook (`hook-settings`) that runs this exact
          argument check, and the write and credential scope, on every tool call.
  grok    --allow/--deny Bash(<glob>), Read, Grep, Write(<path>), Edit(<path>)
  cursor  .cursor/cli.json Shell(<command prefix>), Read(<glob>), Write(<glob>). Prefix rules
          cannot constrain arguments, so cursor's arguments are limited only by the prefixes
          it is allowed and the spelled-out deny prefixes; recorded as a residual risk.
Writes: review may write only its report; resolve may write the worktree and its report.
`.git` (the worktree's pointer file and any .git directory) is never writable.

Usage:
  policy.py rules  --provider P --job review|resolve --adapter F --worktree D --report R
  policy.py cursor-json  (same options)
  policy.py hook-settings (same options)       Claude --settings JSON with the PreToolUse hook
  policy.py hook   (same options)              read a Claude hook event on stdin; exit 2 = deny
  policy.py check  --family glob|prefix --job J --adapter F --worktree D --report R -- COMMAND
                   prints allow or deny: the argument check AND the family's emitted rules
"""
import argparse
import fnmatch
import glob
import json
import os
import re
import shlex
import sys

OPERATOR_CHARS = "();<>|&\n"
SEPARATORS = {"&&", "||", "|", ";", "\n"}
TOOL_CONFIG = (".cursor/", ".grok/", ".claude/", ".agent-pool-context.md")
WILDCARDS = re.compile(r"[*?\[]")
SENSITIVE = ("/.ssh", ".ssh/", ".config/tea", ".config/pulse", ".netrc", ".git-credentials",
             ".config/gh", ".gnupg", ".aws/", ".claude/.credentials", ".codex/auth", "/proc/",
             "/etc/shadow", "gitea_token", "id_rsa", "id_ed25519")

# ---------------------------------------------------------------- argument specs
# flags: exact tokens; valued: options whose value is the next token; eq: --name=value forms;
# attached: regexes for short options with an attached value.
DIFF_FLAGS = {"--stat", "--numstat", "--shortstat", "--name-only", "--name-status", "--summary",
              "-p", "-u", "--patch", "--no-patch", "-s", "--raw", "--cached", "--staged",
              "--no-color", "--word-diff", "--color-words", "-w", "-b", "--ignore-space-change",
              "--ignore-all-space", "--ignore-blank-lines", "--check", "-M", "-C", "--find-renames",
              "--no-renames", "--minimal", "--patience", "--histogram", "--full-index", "--abbrev",
              "--no-ext-diff", "--no-textconv", "--merge-base", "--exit-code", "--quiet", "-R",
              "--text", "-z", "--compact-summary"}
DIFF_EQ = {"--stat", "--unified", "--diff-filter", "--word-diff", "--color", "--abbrev",
           "--relative", "--find-renames", "--dirstat", "--inter-hunk-context", "--stat-width",
           "--src-prefix", "--dst-prefix"}
DIFF_ATTACHED = [r"-U\d+", r"-M\d+%?", r"-C\d+%?"]
LOG_FLAGS = DIFF_FLAGS | {"--oneline", "--graph", "--decorate", "--no-decorate", "--all", "--reverse",
                          "--follow", "--merges", "--no-merges", "--first-parent", "--abbrev-commit",
                          "--date-order", "--topo-order", "--left-right", "--cherry-pick", "--boundary",
                          "--no-walk", "--source", "--no-abbrev-commit"}
LOG_EQ = DIFF_EQ | {"--format", "--pretty", "--max-count", "--skip", "--since", "--until", "--after",
                    "--before", "--author", "--committer", "--grep", "--date", "--decorate"}
LOG_VALUED = {"-n", "-S", "-G", "--author", "--grep", "--since", "--until"}
LOG_ATTACHED = DIFF_ATTACHED + [r"-n\d+", r"-\d+", r"-S.+", r"-G.+"]
GIT_SPECS = {
    "diff": dict(flags=DIFF_FLAGS, eq=DIFF_EQ, valued=set(), attached=DIFF_ATTACHED),
    "log": dict(flags=LOG_FLAGS, eq=LOG_EQ, valued=LOG_VALUED, attached=LOG_ATTACHED),
    "show": dict(flags=LOG_FLAGS, eq=LOG_EQ, valued=LOG_VALUED, attached=LOG_ATTACHED),
    "status": dict(flags={"-s", "--short", "-b", "--branch", "--porcelain", "--long", "-u", "-uno",
                          "-unormal", "-uall", "--ignored", "--no-renames", "-z", "--show-stash"},
                   eq={"--porcelain", "--untracked-files", "--ignored", "--ignore-submodules"},
                   valued=set(), attached=[]),
    "rev-parse": dict(flags={"--abbrev-ref", "--short", "--verify", "-q", "--quiet", "--show-toplevel",
                             "--show-prefix", "--is-inside-work-tree", "--symbolic-full-name"},
                      eq={"--short", "--abbrev-ref"}, valued=set(), attached=[]),
    "ls-files": dict(flags={"-c", "--cached", "-m", "--modified", "-o", "--others", "-d", "--deleted",
                            "-s", "--stage", "-u", "--unmerged", "--exclude-standard", "-z",
                            "--full-name", "-t"}, eq=set(), valued=set(), attached=[]),
    "grep": dict(flags={"-n", "--line-number", "-i", "--ignore-case", "-l", "--files-with-matches", "-L",
                        "-w", "--word-regexp", "-E", "--extended-regexp", "-F", "--fixed-strings", "-P",
                        "-c", "--count", "-I", "-h", "-H", "-v", "--invert-match", "--cached",
                        "--untracked", "-q", "--heading", "--break", "-o", "--only-matching", "-W"},
                 eq={"--max-depth", "--context"}, valued={"-e", "-A", "-B", "-C", "-m"},
                 attached=[r"-[ABC]\d+", r"-m\d+"]),
    "blame": dict(flags={"-w", "-M", "-C", "-s", "-e", "-l", "-t", "--porcelain", "--line-porcelain"},
                  eq={"--date"}, valued={"-L"}, attached=[r"-L.+"]),
}
TOOL_SPECS = {
    "cat": dict(flags={"-n", "-b", "-A", "-v", "-E", "-T", "-s"}, eq=set(), valued=set(), attached=[]),
    "ls": dict(flags=set(), eq=set(), valued=set(), attached=[r"-[alhRtrS1dF]+"]),
    "head": dict(flags=set(), eq=set(), valued={"-n", "-c"}, attached=[r"-n\d+", r"-c\d+", r"-\d+"]),
    "tail": dict(flags=set(), eq=set(), valued={"-n", "-c"}, attached=[r"-n\+?\d+", r"-c\d+", r"-\d+"]),
    "wc": dict(flags={"-l", "-w", "-c", "-m", "-L"}, eq=set(), valued=set(), attached=[]),
    "grep": dict(flags={"--line-number", "--ignore-case", "--recursive", "--count", "--invert-match",
                        "--files-with-matches", "--word-regexp", "--fixed-strings", "--extended-regexp"},
                 eq={"--include", "--exclude", "--exclude-dir", "--color", "--max-count"},
                 valued={"-e", "-A", "-B", "-C", "-m"},
                 attached=[r"-[rRnilwEFcvIhHoqsLx]+", r"-[ABC]\d+", r"-m\d+"]),
    "rg": dict(flags={"--hidden", "--files", "--no-heading", "--heading", "--line-number", "--ignore-case",
                      "--fixed-strings", "--count", "--files-with-matches", "--no-ignore", "--smart-case",
                      "--word-regexp", "--invert-match", "--only-matching"},
               eq={"--glob", "--type", "--max-count", "--sort", "--max-depth", "--type-not", "--context"},
               valued={"-e", "-g", "--glob", "-t", "--type", "-T", "-A", "-B", "-C", "-m", "--max-depth", "-M"},
               attached=[r"-[nilwFcvuSsLHNo]+", r"-[ABC]\d+", r"-m\d+"]),
}
GATES = [["npm", "run"], ["npm", "test"], ["dotnet", "build"], ["dotnet", "test"], ["just"],
         ["composer", "test"], ["composer", "lint"], ["php", "artisan", "test"],
         ["vendor/bin/pint"], ["vendor/bin/phpunit"], ["./vendor/bin/pint"], ["./vendor/bin/phpunit"]]
ADAPTER_READS = ("head", "comments", "threads")


def unquoted_brace(command):
    """True if `{` or `}` appears outside quotes, escaped or not: bash could expand it."""
    quote, i = None, 0
    while i < len(command):
        c = command[i]
        if quote == "'":
            if c == "'":
                quote = None
        elif quote == '"':
            if c == "\\":
                i += 1
            elif c == '"':
                quote = None
        elif c == "\\":
            if command[i + 1:i + 2] in ("{", "}"):
                return True
            i += 1
        elif c in "'\"":
            quote = c
        elif c in "{}":
            return True
        i += 1
    return False


def tokenize(command):
    """Return a list of segments (token lists), or None if any denied construct appears."""
    if unquoted_brace(command) or "`" in command or "$" in command:
        return None
    lex = shlex.shlex(command, posix=True, punctuation_chars=OPERATOR_CHARS)
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    try:
        tokens = list(lex)
    except ValueError:
        return None
    segments = [[]]
    for tok in tokens:
        if tok and all(c in OPERATOR_CHARS for c in tok):
            if tok in SEPARATORS or set(tok) <= {";", "\n"}:
                segments.append([])
                continue
            return None
        segments[-1].append(tok)
    return [s for s in segments if s]


def resolved(arg, a):
    """The absolute, normalised path a shell running in the worktree would open for `arg`."""
    p = os.path.expanduser(arg) if arg.startswith("~") else arg
    return os.path.normpath(os.path.join(a.worktree or os.getcwd(), p))


def sensitive(arg, a):
    p = resolved(arg, a) + "/"
    return any(frag in p for frag in SENSITIVE) or any(frag in arg for frag in SENSITIVE)


def roots(a, wildcard=False):
    out = [os.path.realpath(a.worktree or os.getcwd())]
    if a.report and not wildcard:
        out.append(os.path.realpath(os.path.dirname(a.report)))
    return out


def within(path, bases):
    return any(path == b or path.startswith(b.rstrip("/") + "/") for b in bases)


def contained(arg, a):
    """A path argument stays inside the worktree or the runs folder, after ~, .., // and symlinks.
    A wildcard must have a static part inside the worktree, and every match must stay there."""
    if sensitive(arg, a):
        return False
    p = resolved(arg, a)
    if not WILDCARDS.search(p):
        return within(os.path.realpath(p), roots(a))
    static = []
    for part in p.split("/"):
        if WILDCARDS.search(part):
            break
        static.append(part)
    bases = roots(a, wildcard=True)
    if not within(os.path.realpath("/".join(static) or "/"), bases):
        return False
    return all(within(os.path.realpath(m), bases) and not sensitive(m, a) for m in glob.glob(p))


def options_ok(args, spec, positional_ok, value_ok):
    """Vet options against a spec. Positionals go through positional_ok(token, index) and option
    values through value_ok. After `--`, all are positional."""
    i, rest, n = 0, False, 0
    while i < len(args):
        tok = args[i]
        if rest or not tok.startswith("-") or tok == "-":
            if not positional_ok(tok, n):
                return False
            n += 1
        elif tok == "--":
            rest = True
        elif tok in spec["flags"]:
            pass
        elif tok in spec["valued"]:
            i += 1
            if i >= len(args) or not value_ok(args[i]):
                return False
        elif "=" in tok and tok.split("=", 1)[0] in spec["eq"]:
            if not value_ok(tok.split("=", 1)[1]):
                return False
        elif any(re.fullmatch(rx, tok) for rx in spec["attached"]):
            if not value_ok(tok):
                return False
        else:
            return False
        i += 1
    return True


def reader_check(args, spec, a, pattern_first):
    """Readers: every path positional stays contained. For grep-style tools the first positional
    is the search pattern, not a path, unless the pattern came from -e (or rg --files)."""
    explicit = any(t in ("-e", "--regexp", "--files") or t.startswith("--regexp=") for t in args)
    skip = 0 if (explicit or not pattern_first) else 1
    return options_ok(args, spec, lambda t, n: n < skip or contained(t, a), lambda v: not sensitive(v, a))


def add_positional(tok, a):
    if tok.startswith(":") or sensitive(tok, a):
        return False
    wt = os.path.realpath(a.worktree or os.getcwd())
    p = os.path.realpath(resolved(tok, a))
    if not p.startswith(wt + "/"):
        return False
    rel = os.path.relpath(p, wt)
    if rel in (".", "*") or WILDCARDS.fullmatch(rel) or rel.split("/")[0] == ".git":
        return False
    return not any((rel + "/").startswith(t) for t in TOOL_CONFIG)


def segment_ok(seg, a):
    head = seg[0]
    if head == "git":
        if len(seg) < 2:
            return False
        sub, args = seg[1], seg[2:]
        if sub in GIT_SPECS:
            return reader_check(args, GIT_SPECS[sub], a, pattern_first=(sub == "grep"))
        if a.job == "resolve" and sub == "add":
            none = dict(flags=set(), eq=set(), valued=set(), attached=[])
            return bool(args) and options_ok(args, none, lambda t, n: add_positional(t, a), lambda v: False)
        if a.job == "resolve" and sub == "commit":
            spec = dict(flags={"-q", "--quiet", "-s", "--signoff"}, eq={"--message"}, valued={"-m"}, attached=[])
            has_message = any(t == "-m" or t.startswith("--message=") for t in args)
            return has_message and options_ok(args, spec, lambda t, n: False, lambda v: not sensitive(v, a))
        return False
    if head in TOOL_SPECS:
        return reader_check(seg[1:], TOOL_SPECS[head], a, pattern_first=head in ("grep", "rg"))
    if head == "python3":
        if len(seg) < 3 or seg[1] != a.adapter or seg[2] not in ADAPTER_READS:
            return False
        args, seen = seg[3:], set()
        if len(args) != 4:
            return False
        for name, value in (args[0:2], args[2:4]):
            if name not in ("--repo", "--pr") or name in seen or value.startswith("-"):
                return False
            seen.add(name)
        return True
    if a.job == "resolve":
        for gate in GATES:
            if seg[:len(gate)] == gate and (len(seg) > len(gate) or gate != ["npm", "run"]):
                return not any(sensitive(t, a) for t in seg)
    return False


def argument_check(command, a):
    segments = tokenize(command)
    if segments is None:
        return False
    return all(segment_ok(seg, a) for seg in segments)


# ---------------------------------------------------------------- emitted rules
READ_SUBS = ["diff", "log", "show", "status", "rev-parse", "ls-files", "grep", "blame"]
READ_SHELL = [r for sub in READ_SUBS for r in (f"git {sub}", f"git {sub} *")] + \
    ["cat *", "ls", "ls *", "head *", "tail *", "wc *", "grep *", "rg *"]
GATE_SHELL = ["npm run *", "npm test", "npm test *", "dotnet build", "dotnet build *", "dotnet test",
              "dotnet test *", "just", "just *", "composer test", "composer test *", "composer lint",
              "composer lint *", "php artisan test", "php artisan test *", "vendor/bin/pint", "vendor/bin/pint *",
              "vendor/bin/phpunit", "vendor/bin/phpunit *", "./vendor/bin/pint", "./vendor/bin/pint *",
              "./vendor/bin/phpunit", "./vendor/bin/phpunit *"]
COMMIT_SHELL = ["git add *", "git commit -m *"]
DENY_SHELL = [
    "git push*", "*git push*", "git push --force*", "git reset --hard*", "git merge*", "git rebase*",
    "git difftool*", "*--output*", "*>*", "*<*", "*--ext-diff*", "*--textconv*", "* -x *",
    "*{*,*}*", "*{*..*}*", "git commit -F*", "git commit * -F*", "git commit *--file*",
    "git add *.agent-pool-context.md*",
    "git branch -D*", "git config*", "git -C*", "git -c*", "git --*", "git remote*", "git update-ref*",
    "git add -A*", "git add --all*", "git add -u*", "git add .", "git add . *", "git add :/*",
    "git add -f*", "git add --force*", "git add * -f*", "git add * --force*",
    "git add *.cursor/*", "git add *.grok/*", "git add *.claude/*",
    "git commit -a*", "git commit --all*", "git commit --amend*", "git commit * -a*", "git commit * --all*",
    "git commit * --amend*", "*gitea-pr.py comment", "*gitea-pr.py comment *", "*gitea-pr.py label",
    "*gitea-pr.py label *", "*gitea-pr.py merge*",
    "tea", "tea *", "gh", "gh *", "curl*", "wget*", "sudo*", "rm -rf*", "rm -fr*", "systemctl*", "crontab*",
    "python3 -c*", "python3 -", "python3 - *", "node*", "npx*", "bash*", "sh *", "env*", "eval *",
    "*$*", "*`*", "rg *--pre*", "rg *-z*", "rg *--search-zip*", "git grep *-O*", "git grep *--open-files-in-pager*",
    "tail *-f*", "tail *-F*", "*.ssh*", "*.config/tea*", "*.config/pulse*", "*.netrc*", "*.git-credentials*",
    "*/proc/*", "*gitea_token*",
]
REVIEW_DENY_SHELL = ["git add*", "git commit*"]
CURSOR_DENY = ["git push", "git push --force", "git reset --hard", "git merge", "git rebase", "git branch -D",
               "git difftool", "git diff --output", "git log --output", "git show --output",
               "git diff --ext-diff", "git log --ext-diff", "git show --ext-diff",
               "git config", "git -C", "git -c", "git remote", "git update-ref", "git add -A", "git add --all",
               "git add -u", "git add .", "git add -f", "git add --force", "git add .cursor", "git add .grok",
               "git add .claude", "git add .agent-pool-context.md", "git commit -a", "git commit --all",
               "git commit --amend", "git commit -F", "git commit --file",
               "tea", "gh", "curl", "wget", "sudo", "rm -rf", "rm -fr", "systemctl", "crontab",
               "python3 -c", "python3 -", "node", "npx", "bash", "sh", "env", "eval",
               "rg --pre", "rg -z", "rg --search-zip", "git grep -O", "git grep --open-files-in-pager",
               "tail -f", "tail -F", "cat ~/.ssh", "cat ~/.config", "cat ~/.netrc", "cat /proc"]
CURSOR_REVIEW_DENY = ["git add", "git commit"]


def home():
    return os.path.expanduser("~")


def credential_globs():
    h = home()
    return [f"{h}/.ssh/**", f"{h}/.config/tea/**", f"{h}/.config/pulse/**", f"{h}/.netrc",
            f"{h}/.git-credentials", f"{h}/.config/gh/**", "/proc/**"]


def shell_rules(a):
    allow = list(READ_SHELL) + [f"python3 {a.adapter} {sub} *" for sub in ADAPTER_READS]
    deny = list(DENY_SHELL)
    if a.job == "resolve":
        allow += COMMIT_SHELL + GATE_SHELL
    else:
        deny += REVIEW_DENY_SHELL
    return allow, deny


def git_paths(a):
    wt = a.worktree.rstrip("/")
    return [f"{wt}/.git", f"{wt}/.git/**", "**/.git/**"]


def read_roots(a):
    return [x for x in (a.worktree.rstrip("/"), os.path.dirname(a.report).rstrip("/")) if x]


def rules(a):
    allow, deny = shell_rules(a)
    wt = a.worktree.rstrip("/")
    if a.provider == "claude":
        # Claude rule paths: //abs is an absolute path.
        ab = lambda p: "/" + p if p.startswith("/") else p
        tools = [f"Read({ab(r)}/**)" for r in read_roots(a)] + ["Grep", "Glob", f"Write({ab(a.report)})"]
        if a.job == "resolve":
            tools += [f"Edit({ab(wt)}/**)", f"Write({ab(wt)}/**)"]
        denies = [f"Bash({r})" for r in deny]
        denies += [f"{t}({ab(p)})" for p in git_paths(a) for t in ("Edit", "Write")]
        denies += [f"Read({ab(p)})" for p in credential_globs()]
        return tools + [f"Bash({r})" for r in allow], denies
    if a.provider == "grok":
        tools = [f"Read({r}/**)" for r in read_roots(a)] + ["Grep", f"Write({a.report})"]
        if a.job == "resolve":
            tools += [f"Edit({wt}/**)", f"Write({wt}/**)"]
        denies = [f"Bash({r})" for r in deny]
        denies += [f"{t}({p})" for p in git_paths(a) for t in ("Edit", "Write")]
        denies += [f"Read({p})" for p in credential_globs()]
        return tools + [f"Bash({r})" for r in allow], denies
    if a.provider == "cursor":
        prefixes = [r[:-2] if r.endswith(" *") else r.rstrip("*").rstrip() for r in allow]
        allow_rules = [f"Read({r}/**)" for r in read_roots(a)] + [f"Write({a.report})"] + ([f"Write({wt}/**)"] if a.job == "resolve" else [])
        deny_rules = CURSOR_DENY + (CURSOR_REVIEW_DENY if a.job == "review" else [])
        deny_rules += [f"python3 {a.adapter} {sub}" for sub in ("comment", "label", "merge")]
        denies = [f"Shell({p})" for p in deny_rules]
        denies += [f"Write({p})" for p in git_paths(a)] + [f"Read({p})" for p in credential_globs()]
        return allow_rules + [f"Shell({p})" for p in dict.fromkeys(prefixes)], denies
    raise SystemExit(f"policy: no rule translation for provider {a.provider}")


def prefix_match(command, prefix):
    return command == prefix or command.startswith(prefix + " ")


def family_allows(segment, a):
    allow, deny = shell_rules(a)
    if a.family == "prefix":
        allow = [r[:-2] if r.endswith(" *") else r.rstrip("*").rstrip() for r in allow]
        deny = CURSOR_DENY + (CURSOR_REVIEW_DENY if a.job == "review" else []) \
            + [f"python3 {a.adapter} {sub}" for sub in ("comment", "label", "merge")]
        return any(prefix_match(segment, p) for p in allow) and not any(prefix_match(segment, p) for p in deny)
    return any(fnmatch.fnmatchcase(segment, p) for p in allow) and \
        not any(fnmatch.fnmatchcase(segment, p) for p in deny)


def check(a, command):
    if not argument_check(command, a):
        return "deny"
    for seg in tokenize(command):
        if not family_allows(" ".join(seg), a):
            return "deny"
    return "allow"


# ---------------------------------------------------------------- claude hook
def write_allowed(path, a):
    p = os.path.realpath(os.path.join(a.worktree or "/", os.path.expanduser(path)))
    if p == os.path.realpath(a.report):
        return True
    if a.job != "resolve" or not a.worktree:
        return False
    wt = os.path.realpath(a.worktree)
    if not p.startswith(wt + os.sep):
        return False
    rel = os.path.relpath(p, wt)
    parts = rel.split(os.sep)
    return ".git" not in parts and not any((rel + "/").startswith(t) for t in TOOL_CONFIG)


def hook(a):
    try:
        event = json.load(sys.stdin)
    except ValueError:
        print("policy hook: unreadable event", file=sys.stderr)
        return 2
    tool, data = event.get("tool_name", ""), event.get("tool_input") or {}
    if tool == "Bash":
        command = str(data.get("command", ""))
        if check(argparse.Namespace(**{**vars(a), "family": "glob"}), command) != "allow":
            print(f"policy: denied by the pool's worker policy: {command[:200]}", file=sys.stderr)
            return 2
        return 0
    paths = [str(data[k]) for k in ("file_path", "path", "notebook_path") if data.get(k)]
    if tool in ("Read", "Grep", "Glob", "LS", "NotebookRead"):
        reads = list(paths)
        if tool == "Glob" and data.get("pattern"):
            reads.append(os.path.join(paths[0] if paths else (a.worktree or "."), str(data["pattern"])))
        bad = [p for p in reads if not contained(p, a)]
        bad += [str(data["glob"])] if data.get("glob") and sensitive(str(data["glob"]), a) else []
        if bad:
            print(f"policy: read outside the worktree and runs folder denied: {bad[0]}", file=sys.stderr)
            return 2
        return 0
    if tool in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
        bad = [p for p in paths if not write_allowed(p, a)]
        if bad or not paths:
            print(f"policy: write outside the job's scope denied: {(bad or ['?'])[0]}", file=sys.stderr)
            return 2
        return 0
    return 0


def hook_settings(a):
    command = " ".join(shlex.quote(x) for x in [
        sys.executable, os.path.abspath(__file__), "hook", "--job", a.job, "--adapter", a.adapter,
        "--worktree", a.worktree, "--report", a.report])
    return {"hooks": {"PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": command}]}]}}


def main():
    argv = sys.argv[1:]
    command = []
    if "--" in argv:
        split = argv.index("--")
        argv, command = argv[:split], argv[split + 1:]
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("action", choices=["rules", "cursor-json", "hook-settings", "hook", "check"])
    p.add_argument("--provider", default="")
    p.add_argument("--family", choices=["glob", "prefix"], default="glob")
    p.add_argument("--job", choices=["review", "resolve"], required=True)
    p.add_argument("--adapter", required=True)
    p.add_argument("--worktree", default="")
    p.add_argument("--report", default="")
    a = p.parse_args(argv)
    if a.action == "check":
        print(check(a, " ".join(command)))
        return 0
    if a.action == "hook":
        return hook(a)
    if a.action == "hook-settings":
        print(json.dumps(hook_settings(a)))
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
