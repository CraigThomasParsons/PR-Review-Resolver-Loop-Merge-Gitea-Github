#!/usr/bin/env python3
"""repoconfig.py: which repos each provider's prod ticks, and which abilities it may use there.

The file is TOML, ~/.config/agent-pool/repos.toml unless AGENT_POOL_CONFIG names another;
agent-pool/config/repos.example.toml is the annotated example. Shape:

  [pool]
  providers = ["claude", "codex"]     # the roster: providers whose prods run on this host
                                      # (default: claude, cursor, grok, agy, codex)
  [repos."owner/name"]
  main = "/path/to/clone"             # the clone a prod ticks; without it the repo is only
                                      # policed by the doctor
  abilities = ["review", "resolve"]   # default ["review"]
  nightcrew_hold = true               # AGENT_POOL_NIGHTCREW_HOLD=1 for this repo's ticks
  [repos."owner/name".providers.codex]
  abilities = ["review"]              # narrows one provider on this repo; never widens

Abilities are exactly plan, review, prototype, test-author and resolve. A repo that is absent,
or has no abilities key, gets review only. Each provider also has a ceiling no configuration
widens: agy never resolves (it has no deny list, and resolving would need
--dangerously-skip-permissions). The ceiling is capabilities.py's static one (capabilities.ceiling,
never its AGENT_POOL_CEILING_<PROVIDER> narrowing, so nothing here depends on a host's
environment). A provider table that lists resolve for agy is warned about and the ability
dropped. Only review and resolve are job kinds prod-common.sh runs today; plan, prototype and
test-author are accepted here so the file does not change when they land.

The host-wide roster, AGENT_POOL_ROSTER, is [pool].providers: the providers whose prods run on
this host. It is the only roster; `roster` prints it for any caller (prod-common.sh, doctor.sh)
that must not re-read the TOML itself. For one job, `roster --repo R --ability A` prints
REPO_ROSTER, the providers in AGENT_POOL_ROSTER whose abilities() on R include A, which is what
capabilities.py check-queue takes as --roster to decide whether anyone can ever take the job.

A missing file is an empty config: every repo is review-only and no repo is ticked. A file that
does not parse, or names an unknown ability, provider or key, is an error (exit 2): a typo must
not silently widen or narrow what runs.

Subcommands:
  abilities --repo R --provider P   print P's effective abilities on R, comma-separated
  ticks --provider P                one line per repo P's prod should tick:
                                    repo<TAB>main<TAB>abilities<TAB>nightcrew_hold (0 or 1).
                                    With AGENT_POOL_REPO set, only that repo (its clone from
                                    AGENT_POOL_MAIN, else the config). Nothing when P is not in
                                    the roster or has no ability on the repo.
  roster [--repo R --ability A]     the host-wide roster AGENT_POOL_ROSTER, comma-separated; with
                                    --repo and --ability, only the providers R grants A to
                                    (REPO_ROSTER). Empty when nobody qualifies.
  check                             validate the file and print what each provider may do
"""
import argparse
import os
import re
import sys
import tomllib
from pathlib import Path
from typing import Any

from capabilities import ABILITIES, PROVIDERS, ceiling

DEFAULT_ABILITIES = ("review",)
REPO_NAME = re.compile(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+")


class ConfigError(Exception):
    """The config file is unusable; nothing should run from it."""


def config_path() -> Path:
    raw = os.environ.get("AGENT_POOL_CONFIG", "").strip()
    return Path(raw).expanduser() if raw else Path.home() / ".config/agent-pool/repos.toml"


def _keys(where: str, table: Any, allowed: set[str]) -> dict:
    if not isinstance(table, dict):
        raise ConfigError(f"{where} must be a table")
    unknown = sorted(set(table) - allowed)
    if unknown:
        raise ConfigError(f"{where}: unknown key(s) {', '.join(unknown)}")
    return table


def _abilities(where: str, value: Any) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(x, str) for x in value):
        raise ConfigError(f"{where}.abilities must be a list of strings")
    unknown = [x for x in value if x not in ABILITIES]
    if unknown:
        raise ConfigError(f"{where}.abilities: unknown ability {unknown[0]!r} "
                          f"(expected one of {', '.join(ABILITIES)})")
    return [x for x in ABILITIES if x in value]


def load(path: Path | None = None) -> dict:
    """Return {"path", "providers", "repos", "warnings"}; raise ConfigError on a bad file."""
    path = path or config_path()
    try:
        raw = tomllib.loads(path.read_text())
    except FileNotFoundError:
        raw = {}
    except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError) as error:
        raise ConfigError(f"cannot read {path}: {error}") from None
    _keys("the config", raw, {"pool", "repos"})
    pool = _keys("[pool]", raw.get("pool", {}), {"providers"})
    providers = pool.get("providers", list(PROVIDERS))
    if not isinstance(providers, list) or not all(isinstance(x, str) for x in providers):
        raise ConfigError("[pool].providers must be a list of strings")
    unknown = [x for x in providers if x not in PROVIDERS]
    if unknown:
        raise ConfigError(f"[pool].providers: unknown provider {unknown[0]!r}")
    warnings: list[str] = []
    repos: dict[str, dict] = {}
    if not isinstance(raw.get("repos", {}), dict):
        raise ConfigError("[repos] must be a table")
    for name, table in raw.get("repos", {}).items():
        where = f"[repos.{name!r}]"
        if not REPO_NAME.fullmatch(name):
            raise ConfigError(f"{where}: a repo is named owner/name")
        _keys(where, table, {"main", "abilities", "nightcrew_hold", "providers"})
        main = table.get("main", "")
        if not isinstance(main, str) or any(c in main for c in "\t\n"):
            raise ConfigError(f"{where}.main must be a path")
        hold = table.get("nightcrew_hold", False)
        if not isinstance(hold, bool):
            raise ConfigError(f"{where}.nightcrew_hold must be true or false")
        repo = {"main": os.path.expanduser(main) if main else "", "nightcrew_hold": hold,
                "abilities": _abilities(where, table.get("abilities", list(DEFAULT_ABILITIES))),
                "providers": {}}
        for prov, ptable in _keys(f"{where}.providers", table.get("providers", {}),
                                  set(PROVIDERS)).items():
            pwhere = f"{where}.providers.{prov}"
            _keys(pwhere, ptable, {"abilities"})
            narrowed = _abilities(pwhere, ptable.get("abilities", []))
            for ability in narrowed:
                if ability not in ceiling(prov):
                    warnings.append(f"{pwhere}: {prov} can never take {ability}; ignored")
            repo["providers"][prov] = narrowed
        repos[name] = repo
    return {"path": str(path), "providers": providers, "repos": repos, "warnings": warnings}


def abilities(cfg: dict, repo: str, provider: str) -> list[str]:
    """The abilities `provider` may use on `repo`: the repo's list, narrowed by the provider's
    own table there, capped by the provider's ceiling. An unknown repo is review-only."""
    if provider not in PROVIDERS:
        return []
    entry = cfg["repos"].get(repo)
    granted = set(entry["abilities"]) if entry else set(DEFAULT_ABILITIES)
    if entry and provider in entry["providers"]:
        granted &= set(entry["providers"][provider])
    granted &= set(ceiling(provider))
    return [x for x in ABILITIES if x in granted]


def roster(cfg: dict, repo: str = "", ability: str = "") -> list[str]:
    """AGENT_POOL_ROSTER ([pool].providers); with repo and ability, only the providers whose
    abilities on that repo include it (REPO_ROSTER). A grant on another repo never counts."""
    if not repo:
        return list(cfg["providers"])
    return [p for p in cfg["providers"] if ability in abilities(cfg, repo, p)]


def ticks(cfg: dict, provider: str) -> list[tuple[str, str, list[str], bool]]:
    """(repo, main, abilities, nightcrew_hold) for every repo `provider`'s prod should tick."""
    if provider not in cfg["providers"]:
        print(f"repoconfig: {provider} is not in the roster ([pool].providers); nothing to tick",
              file=sys.stderr)
        return []
    only = os.environ.get("AGENT_POOL_REPO", "").strip()
    if only:
        entry = cfg["repos"].get(only, {})
        names = [only]
        mains = {only: os.environ.get("AGENT_POOL_MAIN", "").strip() or entry.get("main", "")}
    else:
        names = list(cfg["repos"])
        mains = {n: cfg["repos"][n]["main"] for n in names}
    out = []
    for name in names:
        granted = abilities(cfg, name, provider)
        if not mains[name]:
            print(f"repoconfig: {name} has no main clone configured; not ticked", file=sys.stderr)
        elif not granted:
            print(f"repoconfig: {provider} has no ability on {name}; not ticked", file=sys.stderr)
        else:
            out.append((name, mains[name], granted, bool(cfg["repos"].get(name, {}).get("nightcrew_hold"))))
    return out


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("action", choices=["abilities", "ticks", "roster", "check"])
    p.add_argument("--repo", default="")
    p.add_argument("--provider", default="")
    p.add_argument("--ability", default="")
    a = p.parse_args()
    if a.action in ("abilities", "ticks") and a.provider not in PROVIDERS:
        p.error(f"--provider must be one of {', '.join(PROVIDERS)}")
    if a.action == "abilities" and not a.repo:
        p.error("--repo is required")
    if a.action == "roster" and bool(a.repo) != bool(a.ability):
        p.error("roster takes --repo and --ability together, or neither")
    if a.action == "roster" and a.ability and a.ability not in ABILITIES:
        p.error(f"--ability must be one of {', '.join(ABILITIES)}")
    try:
        cfg = load()
    except ConfigError as error:
        print(f"repoconfig: {error}", file=sys.stderr)
        return 2
    for warning in cfg["warnings"]:
        print(f"repoconfig: warning: {warning}", file=sys.stderr)
    if a.action == "abilities":
        print(",".join(abilities(cfg, a.repo, a.provider)))
    elif a.action == "roster":
        print(",".join(roster(cfg, a.repo, a.ability)))
    elif a.action == "ticks":
        for name, main_dir, granted, hold in ticks(cfg, a.provider):
            print(f"{name}\t{main_dir}\t{','.join(granted)}\t{int(hold)}")
    else:
        print(f"{cfg['path']}: roster {','.join(cfg['providers']) or '(empty)'}")
        for name in cfg["repos"]:
            per = "; ".join(f"{prov}={','.join(abilities(cfg, name, prov)) or '-'}" for prov in cfg["providers"])
            print(f"  {name}: {per}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
