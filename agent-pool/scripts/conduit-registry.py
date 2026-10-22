#!/usr/bin/env python3
"""conduit-registry.py: offline administration and matching for the Conduit registry.

Usage:
  conduit-registry.py migrate       --database PATH
  conduit-registry.py seed-examples --database PATH
  conduit-registry.py apply         --database PATH --config FILE
  conduit-registry.py show          --database PATH --conduit ID
  conduit-registry.py match         --database PATH --conduit ID --request FILE

PATH must be absolute and outside this checkout; only migrate creates it. FILE is JSON: a
configuration document (format conduit-registry/v1, see conduit_registry.py) or a match request
{"capabilities": [...], "permissions": [...], "skills": [{"id", "version", "integrity_sha256"}],
"actor_id", "revision_sha", "authored_by": [...], "approves_revision": bool}.

Every command prints one JSON document on stdout. Exit 0: administrative success, a conduit
shown, or an eligible match. Exit 3: a denied match (including an unknown conduit or an invalid
request) or show of an unknown conduit. Exit 2: malformed input, or a path, storage or schema
failure, with {"error": code, "message": ...} on stderr that never quotes an input value. Nothing
here invokes an agent, a provider CLI or the network.
"""
import argparse
import dataclasses
import json
import sys
from pathlib import Path
from typing import Any

import conduit_registry as registry

EXIT_OK = 0
EXIT_MALFORMED = 2
EXIT_DENIED = 3


def emit(document: Any) -> None:
    print(json.dumps(document, sort_keys=True))


def read_json(path: str, error: type[registry.RegistryError]) -> Any:
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, ValueError) as caught:
        raise error("the input file could not be read as JSON") from caught


def run(a: argparse.Namespace) -> int:
    database = Path(a.database)
    if a.command == "migrate":
        emit({"schema_version": registry.migrate(database)})
        return EXIT_OK
    if a.command == "seed-examples":
        registry.seed_examples(database)
        emit({"seeded": "examples"})
        return EXIT_OK
    if a.command == "apply":
        registry.apply_configuration(database, read_json(a.config, registry.ConfigurationError))
        emit({"applied": True})
        return EXIT_OK
    if a.command == "show":
        snapshot = registry.load_conduit(database, a.conduit)
        emit({"conduit": None if snapshot is None else dataclasses.asdict(snapshot)})
        return EXIT_DENIED if snapshot is None else EXIT_OK
    request = registry.request_from_json(read_json(a.request, registry.MalformedRequestError))
    result = registry.match_conduit(registry.load_conduit(database, a.conduit), request)
    emit({"conduit": a.conduit, "eligible": result.eligible, "reasons": list(result.reasons)})
    return EXIT_OK if result.eligible else EXIT_DENIED


def main() -> int:
    p = argparse.ArgumentParser(description="Offline Conduit registry administration and matching.")
    p.add_argument("command", choices=["migrate", "seed-examples", "apply", "show", "match"])
    p.add_argument("--database", required=True)
    p.add_argument("--config")
    p.add_argument("--conduit")
    p.add_argument("--request")
    a = p.parse_args()
    needs = {"apply": ["config"], "show": ["conduit"], "match": ["conduit", "request"]}
    for option in needs.get(a.command, []):
        if getattr(a, option) is None:
            p.error(f"--{option} is required for {a.command}")
    try:
        return run(a)
    except registry.RegistryError as error:
        print(json.dumps({"error": error.code, "message": str(error)}, sort_keys=True), file=sys.stderr)
        return EXIT_MALFORMED


if __name__ == "__main__":
    sys.exit(main())
