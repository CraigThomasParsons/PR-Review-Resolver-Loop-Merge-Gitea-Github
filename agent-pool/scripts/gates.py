#!/usr/bin/env python3
"""gates.py: the pinned gate manifest (issue #14, docs/plans/controller-gates.md Section 1).

A repo's gates live in `.agent-pool/gates.toml` on its BASE branch, read by blob so only a
merged change can alter them, or in a controller-owned override under
`$AGENT_POOL_GATES_DIR` (default `~/.config/agent-pool/gates/`) which wins when present.
Commands are argv lists, never shell strings, and `argv[0]` must be one of `GATE_RUNNERS`
(the old `policy.GATES` moved here). A manifest that fails validation is an infra fault, not
a gate failure: the caller must not run anything from it.

It also runs the selected gates in a sandbox (`run`, docs/plans/controller-gates.md Section 2)
and keeps the write-once, head-bound gate receipt the controller checks before it pushes
(Section 3). The sandbox is a transient systemd user scope (cgroup limits) around `timeout`
around bubblewrap with every namespace unshared: no network, a tmpfs /home, no /run/user (so
no ssh agent or user bus), a cleared environment, and only the gate checkout writable. If
bwrap, systemd-run or timeout is missing, or the sandbox does not start, the result is infra:
there is no unsandboxed fallback.

`[[deps]]` (Section 2.5) come from a controller-owned cache, one per dep under
`<cache-root>/<repo-slug>/<dep>/`: `cache` (a symlink swapped atomically to the latest good
`cache-*` dir), `warmed.json` and the last warm's log. `warm` fills it from the BASE_SHA tree
in the same sandbox but with network; `run` installs each dep offline from a per-run scratch
copy of it before the gates, which then see the same copy at /cache.

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
  changes --raw F --changed-out C --gitlinks-out G   split `git diff-tree -r -z --raw`
                                        output into the changed paths and the gitlink subset
  docs-only --changed F                exit 0 if every path in F is documentation (*.md, docs/**)
  warm --manifest J --main M --base-sha S --cache-root DIR --repo O/R [--budget N]
                                        for each [[deps]] whose BASE_SHA lockfile blob or
                                        definition differs from its warmed.json, export the
                                        BASE_SHA tree and run `warm` in the sandbox WITH network
                                        into a fresh cache, swapped in only on success; print
                                        {"result": pass | infra, "reason": ..., "deps": [{name,
                                        lockfile, status: fresh | warmed | failed, blob,
                                        base_sha (the commit the cache was warmed from), ...}]}
  run --manifest J --gate-dir D --select F --runs R --tag T --budget N [--lock L]
      [--cache-root DIR --repo O/R]    run each gate named in F (manifest order as given) in
                                        the sandbox against the checkout D; logs and per-gate
                                        JSON go to R/gate-T-<name>.*; print {"result": pass |
                                        gate-fail | gate-timeout | gate-resource | infra,
                                        "reason": ..., "gates": [...], "deps": [...]}. Holds
                                        flock L for the whole run; the wait counts against the
                                        budget N. A manifest with [[deps]] needs --cache-root
                                        and --repo, and a warmed cache for every dep; each
                                        dep's `install` runs first (R/install-T-<dep>.*),
                                        offline, and counts against N
  receipt --state S --repo O/R --pr N --attempt A --provider P --base-sha B --pr-head H
          --head NEW --source SRC --blob SHA --result RES [--reason W] [--run J] [--warm J2]
                                        write S/gates/<repo>__<pr>__<attempt>.json once (exit 3
                                        if it already exists) and the by-head copy; its "deps"
                                        lists each dep of warm's output J2 (name, lockfile,
                                        status, blob, base_sha), empty without one
  check-receipt --state S --repo O/R --pr N --attempt A --head NEW
                                        exit 0 only if this attempt's receipt names NEW and
                                        passed (pass or none-needed)
  annotate --report R --receipt RC --out O   copy R to O with the controller's gate section
                                        and gate marker inserted before the resolve marker

`--manifest J` for select/protected/warm/run accepts either a path to a JSON file holding the
"manifest" object (as produced by `load`) or a literal JSON string.

Knobs: AGENT_POOL_GATE_SANDBOX (bwrap path), AGENT_POOL_GATE_SCOPE (systemd-run path),
AGENT_POOL_GATE_RO_BINDS (colon list of toolchain dirs bound read-only at the same path; each
one, and its bin/, goes first on the gate's PATH; $HOME, its parents and anything holding a
credential directory are refused), AGENT_POOL_GATE_BUDGET (the cap on any manifest's budget).
`--cache-root` follows the same rules, except that it may live under
`$AGENT_POOL_STATE/gate-cache` (default ~/.local/state/agent-pool/gate-cache): only a single
dep's staging dir or a per-run copy is ever bound, never the root or a parent.
Warm, install and the gates all get COMPOSER_CACHE_DIR, COMPOSER_HOME, npm_config_cache and
NUGET_PACKAGES under /cache; install and the gates also get COMPOSER_DISABLE_NETWORK=1.
"""
import argparse
import fcntl
import fnmatch
import hashlib
import json
import os
import posixpath
import re
import resource
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib
from pathlib import Path
from typing import Any

import poolstate

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
DOCS_ONLY = ("*.md", "docs/**")
MEMORY_RX = re.compile(r"^(?:[1-9][0-9]*[KMGT]?|infinity)$")
CPU_RX = re.compile(r"^[1-9][0-9]*%$")
DEP_NAME_RX = re.compile(r"^[A-Za-z0-9_-]+$")

RESULTS_OK = ("pass", "none-needed")
LOG_CAP = 10 * 1024 * 1024
FILE_SIZE_LIMIT = 4 * 1024 ** 3  # RLIMIT_FSIZE for everything under the runner: no disk-filling gate
KILL_GRACE = 30
SANDBOX_HOME = "/home/gate"
# Read-only from the host if present. None holds a secret; passwd and group carry no hashes.
ETC_RO = ("/etc/ssl", "/etc/ca-certificates", "/etc/ld.so.cache", "/etc/alternatives",
          "/etc/passwd", "/etc/group", "/etc/nsswitch.conf", "/etc/localtime")
# Name resolution, bound only into a sandbox that has the network (warm).
ETC_NET_RO = ("/etc/resolv.conf", "/etc/hosts", "/etc/host.conf", "/etc/gai.conf")
# Where every package manager keeps its cache inside the sandbox; /cache is one dep's staging
# dir (warm) or the run's scratch copy (install and gates).
DEP_ENV = {"COMPOSER_CACHE_DIR": "/cache/composer", "COMPOSER_HOME": "/cache/composer-home",
           "npm_config_cache": "/cache/npm", "NUGET_PACKAGES": "/cache/nuget", "HOME": SANDBOX_HOME}
OFFLINE_ENV = {**DEP_ENV, "COMPOSER_DISABLE_NETWORK": "1"}
WARM_TAG = "latest"
INSTALL_FAILED = "dependency install {} failed (the cache may be stale or the worker changed dependencies)"
# Never bound into a gate, nor any directory holding one of them.
SENSITIVE_HOME = (".ssh", ".gnupg", ".config", ".claude", ".codex", ".cursor", ".grok", ".netrc",
                  ".git-credentials", ".npmrc", ".docker", ".aws", ".kube", ".local/share/keyrings",
                  ".local/state")
# systemd-run reaches the user manager through these; bwrap --clearenv drops them for the gate.
SCOPE_ENV = ("XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS")


class ManifestError(Exception):
    """The manifest fails validation; the caller must treat this as an infra fault."""


class SandboxError(Exception):
    """The sandbox can't be built or started; an infra fault, never a gate result."""


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


def _check_relative(where: str, key: str, value: Any, errors: list[str]) -> None:
    if not isinstance(value, str):
        errors.append(_err(where, f"{key} must be a string"))
        return
    norm = posixpath.normpath(value)
    if posixpath.isabs(value) or norm == ".." or norm.startswith("../"):
        errors.append(_err(where, f"{key} {value!r} must be a relative path inside the tree"))
    elif norm != value:
        errors.append(_err(where, f"{key} {value!r} must be normalised (as {norm!r})"))


def _check_cwd(where: str, cwd: Any, errors: list[str]) -> None:
    if cwd in (None, ""):
        return
    _check_relative(where, "cwd", cwd, errors)


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
    if not isinstance(defaults, dict):
        defaults = {}
    budget = defaults.get("budget", BUILTIN_DEFAULTS["budget"])
    if not isinstance(budget, int) or isinstance(budget, bool) or budget <= 0:
        errors.append(_err("defaults.budget", "must be a positive integer of seconds"))
        budget = BUILTIN_DEFAULTS["budget"]
    elif budget > gate_budget():
        errors.append(_err("defaults.budget", f"{budget} exceeds AGENT_POOL_GATE_BUDGET {gate_budget()}"))
    default_timeout = defaults.get("timeout", BUILTIN_DEFAULTS["timeout"])
    _check_timeout("defaults.timeout", default_timeout, budget, errors)
    for key, rx, shape in (("memory", MEMORY_RX, "like 4G"), ("cpu", CPU_RX, "like 200%")):
        if key in defaults and (not isinstance(defaults[key], str) or not rx.match(defaults[key])):
            errors.append(_err(f"defaults.{key}", f"must be a string {shape}"))
    if "tasks" in defaults and (not isinstance(defaults["tasks"], int) or isinstance(defaults["tasks"], bool)
                                or defaults["tasks"] <= 0):
        errors.append(_err("defaults.tasks", "must be a positive integer"))

    names_seen: set[str] = set()
    dep_names: set[str] = set()
    deps = doc.get("deps", [])
    if not isinstance(deps, list):
        errors.append(_err("deps", "must be an array of tables"))
        deps = []
    for i, dep in enumerate(deps):
        where = f"deps[{i}]"
        _check_keys(where, dep, DEPS_KEYS, errors)
        if not isinstance(dep, dict):
            continue
        name = dep.get("name")
        if not name or not isinstance(name, str):
            errors.append(_err(where, "name is required"))
        elif not DEP_NAME_RX.match(name):
            errors.append(_err(where, f"name {name!r} must match [A-Za-z0-9_-]+ (it names a cache directory)"))
        elif name in dep_names:
            errors.append(_err(where, f"duplicate deps name {name!r}"))
        else:
            dep_names.add(name)
        _check_cwd(f"{where}.cwd", dep.get("cwd"), errors)
        lockfile = dep.get("lockfile")
        if not lockfile or not isinstance(lockfile, str):
            errors.append(_err(where, "lockfile is required"))
        elif posixpath.normpath(lockfile) == ".":
            errors.append(_err(f"{where}.lockfile", f"lockfile {lockfile!r} must name a file in the tree"))
        else:
            _check_relative(f"{where}.lockfile", "lockfile", lockfile, errors)
        for phase in ("warm", "install"):
            _check_argv(f"{where}.{phase}", dep.get(phase), errors)

    gates = doc.get("gate", [])
    if not isinstance(gates, list):
        errors.append(_err("gate", "must be an array of tables"))
        gates = []
    for i, gate in enumerate(gates):
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


def _scrubbed_git(*args: str, stdin: str | None = None, env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    """Run git with hooks, system and global config, and HOME all scrubbed."""
    return subprocess.run(
        ["git", "-c", "core.hooksPath=/dev/null", *args],
        env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "GIT_CONFIG_NOSYSTEM": "1",
             "GIT_CONFIG_GLOBAL": "/dev/null", "HOME": "/nonexistent", "LANG": "C.UTF-8",
             "GIT_NO_REPLACE_OBJECTS": "1", "GIT_GRAFT_FILE": "/dev/null", **(env or {})},
        input=stdin, capture_output=True, encoding="utf-8", check=False,
    )


def _blob_sha(main: str, base_sha: str, path: str) -> str:
    proc = _scrubbed_git("-C", main, "rev-parse", "--verify", "-q", f"{base_sha}:{path}")
    return proc.stdout.strip() if proc.returncode == 0 else ""


def _gate_blob(main: str, base_sha: str, path: str) -> tuple[str, str] | None:
    """(blob SHA, contents) of BASE_SHA:path, or None if the blob doesn't exist. The contents
    are read by that SHA, so the receipt's blob is exactly the bytes that were parsed."""
    blob = _blob_sha(main, base_sha, path)
    if not blob:
        return None
    proc = _scrubbed_git("-C", main, "cat-file", "blob", blob)
    return (blob, proc.stdout) if proc.returncode == 0 else None


def _export_tree(main: str, sha: str, dest: str) -> None:
    """SHA's tracked content into the empty dir DEST through a private index, as Section 2.1
    does for the gate checkout: no .git, no hooks, no filters, no export-ignore/export-subst."""
    proc = _scrubbed_git("-C", main, "rev-parse", "--absolute-git-dir")
    gitdir = proc.stdout.strip()
    if proc.returncode != 0 or not gitdir:
        raise SandboxError(f"cannot find the git dir of {main}")
    index = dest + ".index"
    env = {"GIT_INDEX_FILE": index}
    try:
        proc = _scrubbed_git("--git-dir", gitdir, "read-tree", f"{sha}^{{commit}}", env=env)
        if proc.returncode == 0:
            proc = _scrubbed_git("-C", dest, "--git-dir", gitdir, "--work-tree", dest,
                                 "-c", "core.fsmonitor=false", "-c", "filter.lfs.smudge=",
                                 "-c", "filter.lfs.process=", "-c", "filter.lfs.required=false",
                                 "-c", "core.symlinks=true", "-c", "core.autocrlf=false",
                                 "checkout-index", "-a", "-f", env=env)
    finally:
        if os.path.exists(index):
            os.unlink(index)
    if proc.returncode != 0:
        raise SandboxError(f"could not export {sha}: {proc.stderr.strip()[:200]}")


def _text_blob_sha(text: str) -> str:
    """The git blob SHA of text read outside any repo, comparable with a base blob's SHA."""
    proc = _scrubbed_git("hash-object", "--no-filters", "--stdin", stdin=text)
    return proc.stdout.strip() if proc.returncode == 0 else ""


def cmd_load(a: argparse.Namespace) -> int:
    override = gates_dir() / f"{a.repo.replace('/', '__')}.toml"
    if override.is_file():
        with open(override, encoding="utf-8", newline="") as handle:  # exact bytes, for the SHA
            text = handle.read()
        source, blob = "override", _text_blob_sha(text)
    else:
        found = _gate_blob(a.main, a.base_sha, ".agent-pool/gates.toml")
        if found is None:
            print(json.dumps({"source": "none", "blob": "", "manifest": None}))
            return 0
        source, (blob, text) = "base", found

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
    if isinstance(doc, dict) and "manifest" in doc:
        doc = doc["manifest"]
    # `load` prints "manifest": null when the repo has none; the built-in protections still
    # apply then, so treat it as an empty manifest rather than crashing.
    return {} if doc is None else doc


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


def _write_atomic(path: Path, text: str) -> None:
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix="." + path.name + ".")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", errors="surrogateescape") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def cmd_changes(a: argparse.Namespace) -> int:
    """Each `diff-tree -z --raw` record is ":<old mode> <new mode> <old> <new> <status>" then one
    path (two for a copy or rename, which --no-renames should already have ruled out)."""
    parts = Path(a.raw).read_bytes().decode("utf-8", "surrogateescape").split("\0")
    changed: list[str] = []
    gitlinks: list[str] = []
    i = 0
    while i < len(parts) and parts[i].startswith(":"):
        fields = parts[i][1:].split()
        npaths = 2 if fields[4][:1] in ("C", "R") else 1
        paths = parts[i + 1:i + 1 + npaths]
        i += 1 + npaths
        changed += paths
        if "160000" in fields[:2]:
            gitlinks += paths
    if i < len(parts) and any(parts[i:]):
        print(f"gates: unparseable diff-tree record {parts[i][:80]!r}", file=sys.stderr)
        return 2
    _write_atomic(Path(a.changed_out), "".join(p + "\0" for p in changed))
    _write_atomic(Path(a.gitlinks_out), "".join(p + "\0" for p in gitlinks))
    return 0


def cmd_docs_only(a: argparse.Namespace) -> int:
    changed = _changed_paths(a.changed)
    return 0 if changed and all(_matches_any(p, list(DOCS_ONLY)) for p in changed) else 1


# ---------------------------------------------------------------- the sandbox runner
def sandbox_tools() -> dict[str, str]:
    tools = {}
    for key, var, name in (("bwrap", "AGENT_POOL_GATE_SANDBOX", "bwrap"),
                           ("scope", "AGENT_POOL_GATE_SCOPE", "systemd-run"),
                           ("timeout", "", "timeout")):
        raw = os.environ.get(var, "").strip() if var else ""
        path = raw or shutil.which(name, path="/usr/bin:/bin") or ""
        if not os.path.isabs(path) or not os.path.isfile(path) or not os.access(path, os.X_OK):
            raise SandboxError(f"{name} is unavailable ({raw or 'not in /usr/bin or /bin'}); "
                               "gates never run unsandboxed")
        tools[key] = path
    return tools


def _inside(path: str, root: str) -> bool:
    return path == root or path.startswith(root.rstrip("/") + "/")


def ro_binds() -> list[str]:
    home = os.path.realpath(Path.home())
    sensitive = [os.path.join(home, s) for s in SENSITIVE_HOME]
    sensitive.append(os.path.realpath(os.environ.get("AGENT_POOL_STATE") or os.path.join(home, ".local/state/agent-pool")))
    binds = []
    for entry in (x.strip() for x in os.environ.get("AGENT_POOL_GATE_RO_BINDS", "").split(":")):
        if not entry:
            continue
        if not os.path.isabs(entry):
            raise SandboxError(f"AGENT_POOL_GATE_RO_BINDS entry {entry!r} is not an absolute path")
        real = os.path.realpath(entry)
        if real == "/" or _inside(home, real):
            raise SandboxError(f"AGENT_POOL_GATE_RO_BINDS entry {entry!r} is $HOME or a parent of it")
        for s in sensitive:
            if _inside(real, s) or _inside(s, real):
                raise SandboxError(f"AGENT_POOL_GATE_RO_BINDS entry {entry!r} overlaps {s}")
        if not os.path.isdir(real):
            raise SandboxError(f"AGENT_POOL_GATE_RO_BINDS entry {entry!r} is not a directory")
        binds.append(real)
    return binds


def _root_links() -> list[str]:
    """Mirror the host's /bin, /lib... as symlinks into /usr (merged /usr) or read-only binds."""
    args: list[str] = []
    for top in ("/bin", "/sbin", "/lib", "/lib32", "/lib64"):
        if os.path.islink(top):
            args += ["--symlink", os.readlink(top), top]
        elif os.path.isdir(top):
            args += ["--ro-bind", top, top]
    return args


def _gate_path(binds: list[str]) -> list[str]:
    dirs = []
    for bind in binds:
        dirs += [d for d in (os.path.join(bind, "bin"), bind) if os.path.isdir(d)]
    return dirs + ["/usr/bin", "/bin"]


def sandbox_argv(tools: dict[str, str], limits: dict, seconds: int, status_fd: int, gate_dir: str,
                 cwd: str, binds: list[str], argv: list[str], network: bool = False, cache: str = "",
                 extra_env: dict[str, str] | None = None) -> list[str]:
    """NETWORK keeps the host's network namespace (warm only; base-branch code, still no
    credentials). CACHE is bound read-write at /cache."""
    cmd = [tools["scope"], "--user", "--scope", "--quiet", "--collect", "--expand-environment=no",
           "-p", f"MemoryMax={limits['memory']}", "-p", "MemorySwapMax=0",
           "-p", f"TasksMax={limits['tasks']}", "-p", f"CPUQuota={limits['cpu']}", "--",
           # --foreground keeps timeout in the runner's process group, so the claim watcher's
           # group kill reaches it; bwrap --die-with-parent then takes the sandbox down too.
           tools["timeout"], "--foreground", "-k", str(KILL_GRACE), str(seconds),
           tools["bwrap"], "--unshare-all", *(["--share-net"] if network else []),
           "--die-with-parent", "--new-session", "--clearenv",
           "--json-status-fd", str(status_fd), "--ro-bind", "/usr", "/usr", *_root_links()]
    for path in ETC_RO + (ETC_NET_RO if network else ()):
        cmd += ["--ro-bind-try", path, path]
    cmd += ["--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp", "--tmpfs", "/home", "--dir", SANDBOX_HOME]
    for bind in binds:
        cmd += ["--ro-bind", bind, bind]
    if cache:
        cmd += ["--bind", cache, "/cache"]
    cmd += ["--bind", gate_dir, "/work", "--chdir", posixpath.join("/work", cwd) if cwd else "/work"]
    env = {"HOME": SANDBOX_HOME, "PATH": ":".join(_gate_path(binds)), "CI": "1", "LANG": "C.UTF-8",
           "TERM": "dumb", "TMPDIR": "/tmp", "DOTNET_CLI_TELEMETRY_OPTOUT": "1", "DOTNET_NOLOGO": "1"}
    env.update(extra_env or {})
    for key, value in env.items():
        cmd += ["--setenv", key, value]
    return cmd + ["--", *argv]


def _scope_env() -> dict[str, str]:
    env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"}
    env.update({k: os.environ[k] for k in SCOPE_ENV if os.environ.get(k)})
    return env


def _limit_file_size() -> None:
    resource.setrlimit(resource.RLIMIT_FSIZE, (FILE_SIZE_LIMIT, FILE_SIZE_LIMIT))


def _read_status(path: Path) -> dict:
    status: dict = {}
    for line in path.read_text(errors="replace").splitlines():
        try:
            doc = json.loads(line)
        except ValueError:
            continue
        if isinstance(doc, dict):
            status.update(doc)
    return status


def _cap_log(path: Path) -> None:
    if path.stat().st_size > LOG_CAP:
        with open(path, "r+b") as log:
            log.truncate(LOG_CAP)
            log.seek(0, os.SEEK_END)
            log.write(b"\n[truncated]\n")


def _log_tail(path: Path) -> str:
    """The last non-blank log line, for infra reasons only: those stay in the local log and are
    never posted."""
    try:
        lines = [x for x in path.read_text(errors="replace").splitlines() if x.strip()]
    except OSError:
        return ""
    return lines[-1][:200] if lines else ""


def classify(rc: int, status: dict, elapsed: float, seconds: int, hard_killed: bool, tail: str) -> tuple[str, str]:
    if "child-pid" not in status:
        return "infra", f"the sandbox did not start (exit {rc}): {tail or 'no output'}"
    if hard_killed or rc == 124 or (rc in (137, -9) and elapsed >= seconds):
        return "gate-timeout", f"timed out after {seconds}s"
    code = status.get("exit-code")
    if code is None:
        if rc < 0 or rc in (137, 143):
            return "gate-resource", f"was killed by signal {abs(rc) if rc < 0 else rc - 128} (likely its memory or task limit)"
        return "infra", f"the sandbox failed after it started (exit {rc}): {tail or 'no output'}"
    if code in (126, 127):
        return "infra", f"exited {code}: the toolchain is not available inside the sandbox"
    if code == 137:
        return "gate-resource", "was killed (likely its memory or task limit)"
    if code != 0:
        return "gate-fail", f"exited {code}"
    return "pass", ""


def _runner_found(argv0: str, binds: list[str]) -> bool:
    if "/" in argv0:
        return True  # tree-relative (vendor/bin/...): bwrap's execvp failure reports it
    return any(os.access(os.path.join(d, argv0), os.X_OK) for d in _gate_path(binds))


def run_one(gate: dict, limits: dict, seconds: int, gate_dir: str, binds: list[str],
            tools: dict[str, str], runs: Path, tag: str, kind: str = "gate", network: bool = False,
            cache: str = "", extra_env: dict[str, str] | None = None) -> dict:
    """Run one argv (a gate, or a dep's warm or install: KIND names its files and reasons)."""
    name = gate["name"]
    stem = runs / f"{kind}-{tag}-{poolstate.slug(name)}"
    log_path, status_path = Path(f"{stem}.log"), Path(f"{stem}.status")
    record = {"name": name, "argv": gate["argv"], "cwd": gate.get("cwd", ""), "rc": None,
              "exit_code": None, "secs": 0, "result": "", "reason": "", "log": log_path.name}
    if not _runner_found(gate["argv"][0], binds):
        record.update(result="infra", reason=f"{kind} {name!r}: {gate['argv'][0]!r} is not on the sandbox PATH "
                                             "(add its toolchain to AGENT_POOL_GATE_RO_BINDS)")
        return record
    status_fd = os.open(status_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    started = time.monotonic()
    hard_killed = False
    try:
        cmd = sandbox_argv(tools, limits, seconds, status_fd, gate_dir, gate.get("cwd", ""), binds, gate["argv"],
                           network=network, cache=cache, extra_env=extra_env)
        with open(log_path, "wb") as log:
            try:
                proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=log, stderr=log, env=_scope_env(),
                                        pass_fds=(status_fd,), preexec_fn=_limit_file_size)
            except OSError as error:
                raise SandboxError(f"could not start the sandbox: {error}") from error
            try:
                rc = proc.wait(timeout=seconds + KILL_GRACE + 15)
            except subprocess.TimeoutExpired:
                proc.kill()
                rc = proc.wait()
                hard_killed = True
    finally:
        os.close(status_fd)
    elapsed = time.monotonic() - started
    _cap_log(log_path)
    status = _read_status(status_path)
    result, reason = classify(rc, status, elapsed, seconds, hard_killed, _log_tail(log_path))
    if result == "infra":
        reason = f"{kind} {name!r}: {reason}"
    elif result != "pass":
        reason = f"{kind} {name!r} {reason}"
    record.update(rc=rc, exit_code=status.get("exit-code"), secs=round(elapsed), result=result, reason=reason)
    poolstate.save(Path(f"{stem}.json"), record)
    return record


def _acquire(lock_path: str, deadline: float) -> int | None:
    descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    while True:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return descriptor
        except BlockingIOError:
            if time.monotonic() >= deadline:
                os.close(descriptor)
                return None
            time.sleep(1)


def _valid_manifest(raw: str, allow_none: bool = False) -> dict:
    try:
        manifest = _load_manifest_arg(raw)
    except (OSError, ValueError) as error:
        raise SandboxError(f"the manifest JSON is unreadable: {error}") from error
    if allow_none and not manifest:
        return {}
    errors = validate(manifest)
    if errors:
        raise SandboxError(f"the manifest fails validation: {errors[0]}")
    return manifest


# ---------------------------------------------------------------- the dependency cache
def cache_root(raw: str) -> Path:
    """The real path of --cache-root, held to ro_binds()'s rules except that it may sit under
    the pool's own <state>/gate-cache. Only one dep's staging dir or a per-run copy is ever
    bound, never this root, so that exception exposes nothing else under the state dir."""
    home = os.path.realpath(Path.home())
    state = os.path.realpath(os.environ.get("AGENT_POOL_STATE") or os.path.join(home, ".local/state/agent-pool"))
    real = os.path.realpath(raw)
    if _inside(real, os.path.join(state, "gate-cache")):
        return Path(real)
    if real == "/" or _inside(home, real):
        raise SandboxError(f"the cache root {raw!r} is $HOME or a parent of it")
    for s in [os.path.join(home, s) for s in SENSITIVE_HOME] + [state]:
        if _inside(real, s) or _inside(s, real):
            raise SandboxError(f"the cache root {raw!r} overlaps {s}")
    return Path(real)


def dep_dir(root: Path, repo: str, name: str) -> Path:
    return root / poolstate.slug(repo) / name


def dep_hash(dep: dict) -> str:
    """What a warmed cache depends on besides the lockfile blob; `install` is not part of it."""
    warm_def = {"name": dep["name"], "cwd": dep.get("cwd") or "", "lockfile": dep["lockfile"], "warm": dep["warm"]}
    return hashlib.sha256(json.dumps(warm_def, sort_keys=True).encode()).hexdigest()


def _rmtree(path: str) -> None:
    """Remove a tree a package manager may have left read-only; symlinks are never followed."""
    for top, dirs, _ in os.walk(path):
        for entry in [top] + [os.path.join(top, d) for d in dirs]:
            if not os.path.islink(entry):
                try:
                    os.chmod(entry, 0o700)
                except OSError:
                    pass
    shutil.rmtree(path, ignore_errors=True)


def _fsync_dir(path: Path) -> None:
    directory = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def _swap_cache(depdir: Path, staging: str) -> None:
    """Point DEPDIR/cache at STAGING with one rename, then drop the previous cache. Readers
    copy under a shared flock on cache.lock, so the old one is never removed mid-copy."""
    link = depdir / "cache"
    with open(depdir / "cache.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        old = os.path.realpath(link) if os.path.lexists(link) else ""
        if os.path.isdir(link) and not os.path.islink(link):
            old = f"{link}.old-{os.getpid()}"
            os.rename(link, old)
        temporary = depdir / f".cache.{os.getpid()}"
        if os.path.lexists(temporary):
            os.unlink(temporary)
        os.symlink(os.path.basename(staging), temporary)
        os.replace(temporary, link)
        _fsync_dir(depdir)
        if old and old != os.path.realpath(staging) and _inside(old, str(depdir)) and old != str(depdir):
            _rmtree(old)


def _warm_dep(dep: dict, a: argparse.Namespace, root: Path, defaults: dict, deadline: float) -> dict:
    name, lockfile = dep["name"], dep["lockfile"]
    blob = _blob_sha(a.main, a.base_sha, lockfile)
    if not blob:
        raise SandboxError(f"its lockfile {lockfile} does not exist at {a.base_sha}")
    depdir = dep_dir(root, a.repo, name)
    depdir.mkdir(parents=True, exist_ok=True, mode=0o700)
    want = dep_hash(dep)
    lock = _acquire(str(depdir / "warm.lock"), deadline)
    if lock is None:
        raise SandboxError("another warm of it held its lock until the budget ran out")
    try:
        warmed = poolstate.load(depdir / "warmed.json")
        if (isinstance(warmed, dict) and warmed.get("blob") == blob and warmed.get("dep_hash") == want
                and (depdir / "cache").is_dir()):
            return {"status": "fresh", "blob": blob, "base_sha": warmed.get("base_sha") or ""}
        left = int(deadline - time.monotonic())
        if left < 1:
            raise SandboxError("the warm budget ran out before it started")
        tools, binds = sandbox_tools(), ro_binds()
        work = tempfile.mkdtemp(dir=depdir, prefix="work-")
        staging = tempfile.mkdtemp(dir=depdir, prefix="cache-")
        try:
            _export_tree(a.main, a.base_sha, work)
            record = run_one({"name": name, "argv": dep["warm"], "cwd": dep.get("cwd", "")}, defaults, left,
                             work, binds, tools, depdir, WARM_TAG, kind="warm", network=True, cache=staging,
                             extra_env=DEP_ENV)
            if record["result"] != "pass":
                raise SandboxError(f"{record['reason']} (log {depdir / record['log']}); the previous cache is kept")
            _swap_cache(depdir, staging)
            staging = ""
            poolstate.save(depdir / "warmed.json", {"lockfile": lockfile, "blob": blob, "base_sha": a.base_sha,
                                                    "dep_hash": want, "warmed_at": poolstate.now()})
            return {"status": "warmed", "blob": blob, "base_sha": a.base_sha, "secs": record["secs"],
                    "log": record["log"]}
        finally:
            _rmtree(work)
            if staging:
                _rmtree(staging)
    finally:
        os.close(lock)


def cmd_warm(a: argparse.Namespace) -> int:
    started = time.monotonic()
    out: dict[str, Any] = {"result": "pass", "reason": "", "deps": []}
    try:
        manifest = _valid_manifest(a.manifest, allow_none=True)
        deps = manifest.get("deps", [])
        root = cache_root(a.cache_root) if deps else None
        defaults = {**BUILTIN_DEFAULTS, **manifest.get("defaults", {})}
        deadline = started + (a.budget if a.budget is not None else defaults["budget"])
        for dep in deps:
            record: dict[str, Any] = {"name": dep["name"], "lockfile": dep["lockfile"], "status": "failed",
                                      "blob": "", "base_sha": "", "reason": ""}
            try:
                record.update(_warm_dep(dep, a, root, defaults, deadline))
            except (SandboxError, OSError) as error:
                record.update(status="failed", reason=f"warming dependency cache {dep['name']}: {error}")
                if out["result"] == "pass":
                    out.update(result="infra", reason=record["reason"])
            out["deps"].append(record)
    except (SandboxError, OSError) as error:
        out.update(result="infra", reason=str(error))
    print(json.dumps(out))
    return 0


def _warmed_dirs(a: argparse.Namespace, deps: list[dict]) -> list[Path]:
    if not a.cache_root or not a.repo:
        raise SandboxError("the manifest declares [[deps]], so run needs --cache-root and --repo")
    root = cache_root(a.cache_root)
    dirs = []
    for dep in deps:
        depdir = dep_dir(root, a.repo, dep["name"])
        warmed = poolstate.load(depdir / "warmed.json")
        if not isinstance(warmed, dict) or warmed.get("_unreadable") or not (depdir / "cache").is_dir():
            raise SandboxError(f"dependency cache for {dep['name']} is not warmed")
        if warmed.get("dep_hash") != dep_hash(dep):
            raise SandboxError(f"dependency cache for {dep['name']} was warmed for a different [[deps]] "
                               "definition; warm it again")
        dirs.append(depdir)
    return dirs


def _copy_caches(dirs: list[Path], scratch: str) -> None:
    """Every dep's cache, merged into SCRATCH (composer refuses a read-only cache dir)."""
    try:
        for depdir in dirs:
            with open(depdir / "cache.lock", "a") as lock:
                fcntl.flock(lock, fcntl.LOCK_SH)
                shutil.copytree(os.path.realpath(depdir / "cache"), scratch, symlinks=True, dirs_exist_ok=True)
    except (OSError, shutil.Error) as error:
        raise SandboxError(f"could not copy the dependency caches: {error}") from error


def cmd_run(a: argparse.Namespace) -> int:
    started = time.monotonic()
    out: dict[str, Any] = {"result": "pass", "reason": "", "gates": [], "deps": []}
    scratch = ""
    try:
        manifest = _valid_manifest(a.manifest)
        names = _changed_paths(a.select)
        gates = {gate["name"]: gate for gate in manifest.get("gate", [])}
        missing = [n for n in names if n not in gates]
        if missing:
            raise SandboxError(f"no gate named {missing[0]!r} in the manifest")
        deps = manifest.get("deps", [])
        dirs = _warmed_dirs(a, deps) if deps else []
        tools = sandbox_tools()
        binds = ro_binds()
        defaults = {**BUILTIN_DEFAULTS, **manifest.get("defaults", {})}
        deadline = started + min(a.budget, defaults["budget"])
        if not os.path.isdir(a.gate_dir) or os.path.lexists(os.path.join(a.gate_dir, ".git")):
            raise SandboxError("the gate checkout is missing or is a git checkout")
        lock = _acquire(a.lock, deadline) if a.lock else None
        if a.lock and lock is None:
            out.update(result="gate-timeout", reason="the job's gate budget ran out waiting for the host-wide gate lock")
            names = []
        extra_env: dict[str, str] = {}
        if deps and names:
            try:
                scratch = tempfile.mkdtemp(dir=a.runs, prefix=f"gate-cache-{poolstate.slug(a.tag)}-")
            except OSError as error:
                raise SandboxError(f"could not make the run's dependency cache copy: {error}") from error
            _copy_caches(dirs, scratch)
            extra_env = OFFLINE_ENV
        for dep in deps if names else []:
            left = int(deadline - time.monotonic())
            if left < 1:
                out["deps"].append({"name": dep["name"], "argv": dep["install"], "result": "gate-timeout",
                                    "reason": f"dependency install {dep['name']} never started: the job's gate budget ran out"})
                out.update(result="gate-timeout", reason=out["deps"][-1]["reason"])
                names = []
                break
            record = run_one({"name": dep["name"], "argv": dep["install"], "cwd": dep.get("cwd", "")}, defaults,
                             min(defaults["timeout"], left), a.gate_dir, binds, tools, Path(a.runs), a.tag,
                             kind="install", cache=scratch, extra_env=extra_env)
            if record["result"] == "gate-fail":
                record["reason"] = INSTALL_FAILED.format(dep["name"])
            out["deps"].append(record)
            if record["result"] != "pass":
                out.update(result=record["result"], reason=record["reason"])
                names = []
                break
        for name in names:
            left = int(deadline - time.monotonic())
            if left < 1:
                out["gates"].append({"name": name, "argv": gates[name]["argv"], "result": "gate-timeout",
                                     "reason": f"gate {name!r} never started: the job's gate budget ran out"})
                out.update(result="gate-timeout", reason=out["gates"][-1]["reason"])
                break
            seconds = min(gates[name].get("timeout", defaults["timeout"]), left)
            record = run_one(gates[name], defaults, seconds, a.gate_dir, binds, tools, Path(a.runs), a.tag,
                             cache=scratch, extra_env=extra_env)
            out["gates"].append(record)
            if record["result"] != "pass":
                out.update(result=record["result"], reason=record["reason"])
                break
    except SandboxError as error:
        out.update(result="infra", reason=str(error))
    finally:
        if scratch:
            _rmtree(scratch)
    print(json.dumps(out))
    return 0


# ---------------------------------------------------------------- receipts
def receipt_paths(state: str, repo: str, pr: int, attempt: str, head: str) -> tuple[Path, Path]:
    root = Path(state) / "gates"
    stem = f"{poolstate.slug(repo)}__{int(pr)}"
    return root / f"{stem}__{poolstate.slug(attempt)}.json", root / "by-head" / f"{stem}__{poolstate.slug(head)}.json"


def _write_once(path: Path, doc: dict) -> bool:
    """Create PATH with DOC, read-only, unless it already exists. os.link refuses an existing
    target, so two writers can't both win and nobody can replace a receipt in place."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix="." + path.name + ".")
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(doc, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o444)
        try:
            os.link(temporary, path)
        except FileExistsError:
            return False
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        return True
    finally:
        os.unlink(temporary)


def _json_doc(path: str | None) -> dict:
    """PATH's JSON object; {} when PATH is unset, missing, unreadable or not an object."""
    if not path or not os.path.isfile(path):
        return {}
    try:
        doc = json.loads(Path(path).read_text() or "{}")
    except (OSError, ValueError):
        return {}
    return doc if isinstance(doc, dict) else {}


def receipt_deps(warm: dict) -> list[dict]:
    """The lockfile blob each dep's cache was warmed from, as `warm` reported it."""
    deps = warm.get("deps")
    return [{key: str(dep.get(key) or "") for key in ("name", "lockfile", "status", "blob", "base_sha")}
            for dep in (deps if isinstance(deps, list) else []) if isinstance(dep, dict)]


def cmd_receipt(a: argparse.Namespace) -> int:
    run = _json_doc(a.run)
    doc = {"version": 1, "repo": a.repo, "pr": int(a.pr), "attempt_id": a.attempt, "provider": a.provider,
           "base_sha": a.base_sha, "pr_head": a.pr_head, "head": a.head,
           "manifest": {"source": a.source, "blob": a.blob}, "result": a.result, "reason": a.reason,
           "gates": run.get("gates", []), "deps": receipt_deps(_json_doc(a.warm)), "created_at": poolstate.now()}
    attempt_path, head_path = receipt_paths(a.state, a.repo, a.pr, a.attempt, a.head)
    if not _write_once(attempt_path, doc):
        print(f"gates: a receipt for attempt {a.attempt} already exists; it is never rewritten", file=sys.stderr)
        return 3
    poolstate.save(head_path, doc)
    print(attempt_path)
    return 0


def cmd_check_receipt(a: argparse.Namespace) -> int:
    path, _ = receipt_paths(a.state, a.repo, a.pr, a.attempt, a.head)
    doc = poolstate.load(path)
    if not isinstance(doc, dict) or doc.get("_unreadable"):
        print(f"gates: no readable gate receipt for attempt {a.attempt}", file=sys.stderr)
        return 1
    if doc.get("attempt_id") != a.attempt or doc.get("head") != a.head:
        print(f"gates: the receipt names attempt {doc.get('attempt_id')} at {doc.get('head')}, "
              f"not {a.attempt} at {a.head}", file=sys.stderr)
        return 1
    if doc.get("result") not in RESULTS_OK:
        print(f"gates: the receipt's result is {doc.get('result')}", file=sys.stderr)
        return 1
    return 0


def _cell(text: str) -> str:
    return text.replace("|", "\\|").replace("`", "'")


def render_section(doc: dict) -> str:
    result, head, blob = doc["result"], doc["head"], doc["manifest"]["blob"]
    lines = ["### Gates (run by the pool controller)", ""]
    if result == "none-needed":
        lines.append(f"No gate applies to the changed paths at `{head}`.")
    else:
        lines += [f"Result: **{result}** at `{head}`, from the {doc['manifest']['source']} manifest "
                  f"(blob `{blob[:12]}`), in a sandbox with no network and no credentials.", "",
                  "| Gate | Command | Result | Seconds |", "|---|---|---|---|"]
        for gate in doc.get("gates", []):
            lines.append(f"| {_cell(gate['name'])} | `{_cell(shlex.join(gate['argv']))}` | "
                         f"{gate.get('result', '')} | {gate.get('secs', '')} |")
        deps = doc.get("deps") or []
        if deps:
            lines += ["", "Dependencies were installed offline from the controller's cache, warmed from the base "
                      "branch's lockfiles: " + ", ".join(
                          f"{_cell(dep.get('name', ''))} (`{_cell(dep.get('lockfile', ''))}` blob "
                          f"`{dep.get('blob', '')[:12]}`)" for dep in deps) + "."]
    lines += ["", f"<!-- agent-pool-gates:v1 head={head} manifest={blob or 'none'} result={result} -->", "", ""]
    return "\n".join(lines)


def cmd_annotate(a: argparse.Namespace) -> int:
    doc = json.loads(Path(a.receipt).read_text())
    body = Path(a.report).read_text(errors="replace")
    lines = body.splitlines(keepends=True)
    at = max((i for i, line in enumerate(lines) if "<!-- pulse-resolve:v1" in line), default=None)
    section = render_section(doc)
    if at is None:
        text = body.rstrip("\n") + "\n\n" + section
    else:
        text = "".join(lines[:at]) + ("" if at == 0 or lines[at - 1].strip() == "" else "\n") + section + "".join(lines[at:])
    _write_atomic(Path(a.out), text)
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("action", choices=["validate", "load", "select", "protected", "changes", "docs-only", "warm",
                                      "run", "receipt", "check-receipt", "annotate"])
    for flag in ("--file", "--main", "--base-sha", "--repo", "--manifest", "--changed", "--raw", "--changed-out",
                 "--gitlinks-out", "--gate-dir", "--select", "--runs", "--tag", "--lock", "--cache-root", "--state",
                 "--pr", "--attempt", "--provider", "--pr-head", "--head", "--source", "--blob", "--result", "--run",
                 "--warm", "--report", "--receipt", "--out"):
        p.add_argument(flag)
    p.add_argument("--gitlinks", default="")
    p.add_argument("--reason", default="")
    p.add_argument("--budget", type=int)
    a = p.parse_args()
    required = {"validate": ["file"], "load": ["main", "base_sha", "repo"],
                "select": ["manifest", "changed"], "protected": ["manifest", "changed"],
                "changes": ["raw", "changed_out", "gitlinks_out"], "docs-only": ["changed"],
                "warm": ["manifest", "main", "base_sha", "cache_root", "repo"],
                "run": ["manifest", "gate_dir", "select", "runs", "tag", "budget"],
                "receipt": ["state", "repo", "pr", "attempt", "provider", "base_sha", "pr_head", "head", "result"],
                "check-receipt": ["state", "repo", "pr", "attempt", "head"],
                "annotate": ["report", "receipt", "out"]}
    for name in required[a.action]:
        if getattr(a, name) in (None, ""):
            p.error(f"--{name.replace('_', '-')} is required for {a.action}")
    if a.action == "receipt":
        a.source = a.source or "none"
        a.blob = a.blob or ""
    return globals()["cmd_" + a.action.replace("-", "_")](a)


if __name__ == "__main__":
    sys.exit(main())
