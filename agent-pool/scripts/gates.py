#!/usr/bin/env python3
"""gates.py: the pinned gate manifest (issue #14, docs/plans/controller-gates.md Section 1).

A repo's gates live in `.agent-pool/gates.toml` on its BASE branch, read by blob so only a
merged change can alter them, or in a controller-owned override under
`$AGENT_POOL_GATES_DIR` (default `~/.config/agent-pool/gates/`) which wins when present.
Commands are argv lists, never shell strings, and `argv[0]` must be one of `GATE_RUNNERS`
(the old `policy.GATES` moved here). A manifest that fails validation is an infra fault, not
a gate failure: the caller must not run anything from it.

This module only loads, validates, and matches the manifest against a worker's changed
paths. The sandboxed runner (`gates.py run`, docs/plans/controller-gates.md Section 2) is a
later step and is not implemented here.

Subcommands:
  validate --file F                    exit 0 if F parses and passes every rule below, else
                                        print each violation on its own line and exit 2
  load --main M --base-sha S --repo O/R   print {"source": "base"|"override"|"none",
                                        "blob": "<sha>"|"", "manifest": {...}|null}; exit 2
                                        and print violations if a manifest exists but is invalid
  select --manifest J --changed F      print the name of each [[gate]] whose `paths` match a
                                        path in F, one per line, or "none" if no gate matches
  protected --manifest J --changed F [--gitlinks F2]   print each path in F that is
                                        protected (built-ins plus the manifest's `protect`
                                        list), plus every path in F2 (the caller's own
                                        `git diff --raw` mode-160000 subset of F -- a plain
                                        path can't say it's a gitlink), one per line

`--manifest J` for select/protected accepts either a path to a JSON file holding the
"manifest" object (as produced by `load`) or a literal JSON string.
"""
import argparse
import fnmatch
import json
import os
import posixpath
import subprocess
import sys
import tomllib
from pathlib import Path
from typing import Any

GATE_RUNNERS = ("npm", "dotnet", "just", "composer", "php", "vendor/bin/pint", "vendor/bin/phpunit")
DENIED_ARGV0_INFIXES = ("sh", "bash", "env", "node")  # plus any argv[0] starting with "python"
DEFAULTS_KEYS = {"timeout", "memory", "tasks", "cpu", "budget"}
DEPS_KEYS = {"name", "cwd", "lockfile", "warm", "install"}
GATE_KEYS = {"name", "cwd", "argv", "paths", "timeout"}
TOP_KEYS = {"version", "defaults", "deps", "gate", "protect"}
BUILTIN_DEFAULTS = {"timeout": 600, "memory": "4G", "tasks": 512, "cpu": "200%", "budget": 1200}

# Protected whatever the manifest says (docs/plans/controller-gates.md Section 1). A gitlink
# (mode 160000) change can't be detected from a path list alone; the caller must check that
# separately from `git diff --raw`.
BUILTIN_PROTECTED = (
    ".agent-pool/**",
    ".gitattributes", "**/.gitattributes",
    ".gitmodules",
    ".lfsconfig",
    ".cursor/**", ".grok/**", ".claude/**",
    ".agent-pool-context.md",
)


class ManifestError(Exception):
    """The manifest fails validation; the caller must treat this as an infra fault."""


def gate_budget() -> int:
    return int(os.environ.get("AGENT_POOL_GATE_BUDGET", 1200))


def gates_dir() -> Path:
    raw = os.environ.get("AGENT_POOL_GATES_DIR", "").strip()
    return Path(raw).expanduser() if raw else Path.home() / ".config/agent-pool/gates"


def _err(where: str, msg: str) -> str:
    return f"{where}: {msg}"


def _check_keys(where: str, table: dict, allowed: set[str], errors: list[str]) -> None:
    if not isinstance(table, dict):
        errors.append(_err(where, "must be a table"))
        return
    for key in table:
        if key not in allowed:
            errors.append(_err(where, f"unknown key {key!r}"))


def _check_argv(where: str, argv: Any, errors: list[str]) -> None:
    if not isinstance(argv, list) or not argv or not all(isinstance(x, str) for x in argv):
        errors.append(_err(where, "argv must be a non-empty list of strings"))
        return
    head = argv[0]
    if head not in GATE_RUNNERS:
        errors.append(_err(where, f"argv[0] {head!r} is outside GATE_RUNNERS {GATE_RUNNERS}"))
    if head.startswith("python") or any(infix in head for infix in DENIED_ARGV0_INFIXES):
        errors.append(_err(where, f"argv[0] {head!r} looks like an interpreter; denied"))


def _check_cwd(where: str, cwd: Any, errors: list[str]) -> None:
    if cwd in (None, ""):
        return
    if not isinstance(cwd, str):
        errors.append(_err(where, "cwd must be a string"))
        return
    norm = posixpath.normpath(cwd)
    if posixpath.isabs(cwd) or norm == ".." or norm.startswith("../"):
        errors.append(_err(where, f"cwd {cwd!r} must be a relative path inside the tree"))


def _check_timeout(where: str, timeout: Any, budget: int, errors: list[str]) -> None:
    if timeout is None:
        return
    if not isinstance(timeout, int) or isinstance(timeout, bool) or timeout <= 0:
        errors.append(_err(where, "timeout must be a positive integer of seconds"))
    elif timeout > budget:
        errors.append(_err(where, f"timeout {timeout} exceeds the manifest's budget {budget}"))


def validate(doc: Any) -> list[str]:
    """Return every violation found in a parsed manifest; empty means valid."""
    errors: list[str] = []
    if not isinstance(doc, dict):
        return ["manifest: must be a table"]
    _check_keys("manifest", doc, TOP_KEYS, errors)
    if doc.get("version") != 1:
        errors.append(_err("manifest.version", f"must be 1, got {doc.get('version')!r}"))

    defaults = doc.get("defaults", {})
    _check_keys("defaults", defaults, DEFAULTS_KEYS, errors)
    budget = defaults.get("budget", BUILTIN_DEFAULTS["budget"])
    if not isinstance(budget, int) or isinstance(budget, bool) or budget <= 0:
        errors.append(_err("defaults.budget", "must be a positive integer of seconds"))
        budget = BUILTIN_DEFAULTS["budget"]
    elif budget > gate_budget():
        errors.append(_err("defaults.budget", f"{budget} exceeds AGENT_POOL_GATE_BUDGET {gate_budget()}"))
    default_timeout = defaults.get("timeout", BUILTIN_DEFAULTS["timeout"])
    _check_timeout("defaults.timeout", default_timeout, budget, errors)
    for key in ("memory", "cpu"):
        if key in defaults and not isinstance(defaults[key], str):
            errors.append(_err(f"defaults.{key}", "must be a string"))
    if "tasks" in defaults and (not isinstance(defaults["tasks"], int) or isinstance(defaults["tasks"], bool)):
        errors.append(_err("defaults.tasks", "must be an integer"))

    names_seen: set[str] = set()
    for i, dep in enumerate(doc.get("deps", [])):
        where = f"deps[{i}]"
        _check_keys(where, dep, DEPS_KEYS, errors)
        if not isinstance(dep, dict):
            continue
        if not dep.get("name") or not isinstance(dep["name"], str):
            errors.append(_err(where, "name is required"))
        _check_cwd(f"{where}.cwd", dep.get("cwd"), errors)
        if not dep.get("lockfile") or not isinstance(dep.get("lockfile"), str):
            errors.append(_err(where, "lockfile is required"))
        for phase in ("warm", "install"):
            if phase in dep:
                _check_argv(f"{where}.{phase}", dep[phase], errors)

    for i, gate in enumerate(doc.get("gate", [])):
        where = f"gate[{i}]"
        _check_keys(where, gate, GATE_KEYS, errors)
        if not isinstance(gate, dict):
            continue
        name = gate.get("name")
        if not name or not isinstance(name, str):
            errors.append(_err(where, "name is required"))
        elif name in names_seen:
            errors.append(_err(where, f"duplicate gate name {name!r}"))
        else:
            names_seen.add(name)
        _check_cwd(f"{where}.cwd", gate.get("cwd"), errors)
        _check_argv(f"{where}.argv", gate.get("argv"), errors)
        paths = gate.get("paths")
        if not isinstance(paths, list) or not paths or not all(isinstance(x, str) for x in paths):
            errors.append(_err(where, "paths must be a non-empty list of strings"))
        _check_timeout(f"{where}.timeout", gate.get("timeout"), budget, errors)

    protect = doc.get("protect", [])
    if not isinstance(protect, list) or not all(isinstance(x, str) for x in protect):
        errors.append(_err("protect", "must be a list of strings"))
    return errors


def cmd_validate(a: argparse.Namespace) -> int:
    try:
        doc = tomllib.loads(Path(a.file).read_text())
    except (OSError, tomllib.TOMLDecodeError) as error:
        print(f"gates: {a.file}: {error}", file=sys.stderr)
        return 2
    errors = validate(doc)
    for error in errors:
        print(f"gates: {error}", file=sys.stderr)
    return 2 if errors else 0


def _gate_show(main: str, base_sha: str, path: str) -> str | None:
    """`git show BASE_SHA:path` through a scrubbed env; None if the blob doesn't exist."""
    proc = subprocess.run(
        ["git", "-c", "core.hooksPath=/dev/null", "-C", main, "show", f"{base_sha}:{path}"],
        env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "GIT_CONFIG_NOSYSTEM": "1",
             "GIT_CONFIG_GLOBAL": "/dev/null", "HOME": "/nonexistent", "LANG": "C.UTF-8"},
        capture_output=True, text=True, check=False,
    )
    return proc.stdout if proc.returncode == 0 else None


def _gate_blob_sha(main: str, base_sha: str, path: str) -> str:
    proc = subprocess.run(
        ["git", "-C", main, "rev-parse", "--verify", "-q", f"{base_sha}:{path}"],
        env={"PATH": os.environ.get("PATH", "/usr/bin:/bin")},
        capture_output=True, text=True, check=False,
    )
    return proc.stdout.strip()


def cmd_load(a: argparse.Namespace) -> int:
    override = gates_dir() / f"{a.repo.replace('/', '__')}.toml"
    if override.is_file():
        source, blob, text = "override", "", override.read_text()
    else:
        text = _gate_show(a.main, a.base_sha, ".agent-pool/gates.toml")
        if text is None:
            print(json.dumps({"source": "none", "blob": "", "manifest": None}))
            return 0
        source, blob = "base", _gate_blob_sha(a.main, a.base_sha, ".agent-pool/gates.toml")

    try:
        doc = tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        print(f"gates: {source} manifest: {error}", file=sys.stderr)
        return 2
    errors = validate(doc)
    if errors:
        for error in errors:
            print(f"gates: {error}", file=sys.stderr)
        return 2
    print(json.dumps({"source": source, "blob": blob, "manifest": doc}))
    return 0


def _load_manifest_arg(raw: str) -> dict:
    text = Path(raw).read_text() if os.path.isfile(raw) else raw
    doc = json.loads(text)
    return doc.get("manifest", doc) if isinstance(doc, dict) else doc


def _changed_paths(raw: str) -> list[str]:
    text = Path(raw).read_text()
    return [p for p in text.replace("\0", "\n").split("\n") if p]


def _matches_any(path: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatch(path, pattern) for pattern in patterns)


def cmd_select(a: argparse.Namespace) -> int:
    manifest = _load_manifest_arg(a.manifest)
    changed = _changed_paths(a.changed)
    names = [gate["name"] for gate in manifest.get("gate", []) if _matches_any_changed(changed, gate["paths"])]
    print("\n".join(names) if names else "none")
    return 0


def _matches_any_changed(changed: list[str], patterns: list[str]) -> bool:
    return any(_matches_any(path, patterns) for path in changed)


def cmd_protected(a: argparse.Namespace) -> int:
    manifest = _load_manifest_arg(a.manifest)
    changed = _changed_paths(a.changed)
    patterns = list(BUILTIN_PROTECTED) + list(manifest.get("protect", []))
    patterns += [dep["lockfile"] for dep in manifest.get("deps", []) if dep.get("lockfile")]
    hits = {p for p in changed if _matches_any(p, patterns)}
    # A gitlink (submodule pointer) change is always protected, whatever its path, but mode
    # 160000 can't be told from a plain changed-path list -- the caller already has it from
    # `git diff --raw` and passes the gitlink subset of `changed` here separately.
    if a.gitlinks:
        hits |= set(_changed_paths(a.gitlinks))
    print("\n".join(sorted(hits)) if hits else "none")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("action", choices=["validate", "load", "select", "protected"])
    p.add_argument("--file")
    p.add_argument("--main")
    p.add_argument("--base-sha")
    p.add_argument("--repo")
    p.add_argument("--manifest")
    p.add_argument("--changed")
    p.add_argument("--gitlinks", default="")
    a = p.parse_args()
    required = {"validate": ["file"], "load": ["main", "base_sha", "repo"],
                "select": ["manifest", "changed"], "protected": ["manifest", "changed"]}
    for name in required[a.action]:
        if not getattr(a, name):
            p.error(f"--{name.replace('_', '-')} is required for {a.action}")
    return globals()["cmd_" + a.action](a)


if __name__ == "__main__":
    sys.exit(main())
