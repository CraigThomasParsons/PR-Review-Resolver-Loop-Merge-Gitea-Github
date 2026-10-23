"""Behave hooks for conduits.feature: one temporary sandbox per scenario, outside the checkout.

AGENT_POOL_STATE points into the sandbox for the scenario, so a claim or state file written by
anything under test would show up there. Cleanups registered by steps (a held lock, a patch) run
before the sandbox is removed.
"""
import os
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
for _path in (ROOT / "agent-pool" / "scripts", ROOT / "agent-pool" / "tests" / "conduits"):
    if str(_path) not in sys.path:
        sys.path.insert(0, str(_path))


def before_scenario(context, scenario) -> None:
    context.sandbox = Path(tempfile.mkdtemp(prefix="conduit-feature-")).resolve()
    context.db = context.sandbox / "registry.sqlite3"
    context.cleanups = []
    context.saved_state = os.environ.get("AGENT_POOL_STATE")
    os.environ["AGENT_POOL_STATE"] = str(context.sandbox / "state")


def after_scenario(context, scenario) -> None:
    try:
        for cleanup in reversed(context.cleanups):
            cleanup()
    finally:
        if context.saved_state is None:
            os.environ.pop("AGENT_POOL_STATE", None)
        else:
            os.environ["AGENT_POOL_STATE"] = context.saved_state
        shutil.rmtree(context.sandbox, ignore_errors=True)
