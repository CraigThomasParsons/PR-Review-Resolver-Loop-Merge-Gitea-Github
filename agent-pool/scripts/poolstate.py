"""Shared state plumbing for the agent pool: one clock, one atomic writer, one lock shape.

Every file the pool keeps (leases, cooldowns, fault reports) is written the way
tmux-multi-pipeline's lease.py writes its lease: a temp file in the same directory,
flushed and fsynced, os.replace'd over the target, then the directory fsynced. A crash
leaves either the old document or the new one, never half of either.

AGENT_POOL_NOW (Unix seconds) pins the clock so tests can step across a TTL or a
cooldown boundary without sleeping.
"""
import contextlib
import fcntl
import json
import os
import tempfile
import time
from pathlib import Path


def now() -> float:
    pinned = os.environ.get("AGENT_POOL_NOW", "").strip()
    return float(pinned) if pinned else time.time()


def state_dir() -> Path:
    root = os.environ.get("AGENT_POOL_STATE") or str(Path.home() / ".local/state/agent-pool")
    path = Path(root)
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    return path


def save(path: Path, doc) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix="." + path.name + ".")
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(doc, stream, indent=2, sort_keys=True)
            stream.write("\n")
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


def load(path: Path):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        # An unreadable document is treated as absent by callers that can tolerate it,
        # and reported by the ones that cannot; it is never silently rewritten here.
        return {"_unreadable": True}


@contextlib.contextmanager
def locked(path: Path):
    """Hold an exclusive flock on a stable sibling inode while the JSON beside it is replaced."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(str(path) + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def slug(text: str) -> str:
    return "".join(c if c.isalnum() or c in "-." else "_" for c in text)
