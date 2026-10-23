"""conduit_registry.py: the Conduit configuration registry (schema v1) and its deny-by-default matcher.

A Conduit is a named agent identity: a Provider, a ModelPolicy, and explicit grants of
Capabilities (work it can do), Permissions (actions it may take) and versioned Skills (procedures
it follows). None substitutes for another. This module owns a configuration-only SQLite database;
jobs, claims, leases, fences, worker registration, scheduling and attempt receipts stay in the
file-backed claim records (claim-record.py) and never live here.

Storage. Every operation takes an explicit absolute database path outside this checkout, and
importing the module creates nothing. Every connection enables foreign keys and waits at most
BUSY_TIMEOUT_SECONDS for a lock. Writes run in one BEGIN IMMEDIATE transaction and roll back on
any exception, including an interrupt. PRAGMA user_version holds the schema version: migrate()
moves 0 to 1 atomically, leaves 1 alone and refuses anything else without touching it. Reads open
the file read-only and refuse a missing file or a schema other than 1. There is no downgrade and
no reset.

Configuration. apply_configuration() takes one allowlisted, self-contained document (see
CONFIG_FORMAT and the SECTION_KEYS below), validates it completely, rejects credential-shaped
strings without echoing them, and inserts it in one transaction. A row that already exists
identically is left alone; one that differs (including a conduit's grant set or a policy's
models) is a conflict and nothing is written, so operator edits are never overwritten.
seed_examples() applies agent-pool/config/conduits.example.json, deriving each skill's integrity
from its procedure file's bytes.

Matching. match_conduit() is pure: no filesystem, process or network effects. It returns every
applicable denial code, sorted. It is a specification boundary, not a runtime authorization: a
later dispatcher must also resolve a trusted actor identity, enforce policy.py, verify skill
content before use, observe the model that actually ran and audit the registry revision it read.
A model policy's models are declarations, never evidence of the model used.
"""
import contextlib
import hashlib
import json
import re
import sqlite3
from collections.abc import Iterator, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import quote

SCHEMA_VERSION = 1
BUSY_TIMEOUT_SECONDS = 5.0
CONFIG_FORMAT = "conduit-registry/v1"
CHECKOUT_ROOT = Path(__file__).resolve().parents[2]
EXAMPLES_PATH = CHECKOUT_ROOT / "agent-pool" / "config" / "conduits.example.json"

IDENTIFIER = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}")
SKILL_VERSION = re.compile(r"[a-z0-9][a-z0-9.+-]{0,63}")
SHA256_HEX = re.compile(r"[0-9a-f]{64}")
REVISION = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")
ACTOR = re.compile(r"[A-Za-z0-9][A-Za-z0-9._@:/-]{0,127}")
POLICY_KINDS = ("fixed", "allow_list", "auto")
MAX_NAME = 200

DENIAL_CODES = (
    "approval_context_missing", "disabled_configuration", "invalid_model_policy", "invalid_request",
    "missing_capability", "missing_permission", "missing_skill", "self_approval", "unknown_conduit",
)

# The credential shapes report.py refuses to publish, split into named rules so a finding can
# name its rule without quoting the text. Bare 40-hex is absent on purpose: commit SHAs share it.
CREDENTIAL_RULES: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("private-key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----", re.IGNORECASE)),
    ("provider-token", re.compile(
        r"\bgh[pousr]_[A-Za-z0-9]{30,}"
        r"|\bgithub_pat_[A-Za-z0-9_]{30,}"
        r"|\bsk-ant-[A-Za-z0-9_-]{20,}"
        r"|\bsk-[A-Za-z0-9]{32,}"
        r"|\bAKIA[0-9A-Z]{16}\b"
        r"|\bglpat-[A-Za-z0-9_-]{20,}"
        r"|\bxox[abprs]-[A-Za-z0-9-]{10,}", re.IGNORECASE)),
    ("credential-assignment", re.compile(
        r"\b(?:token|bearer)\s+[0-9a-f]{40}\b"
        r"|\b[\w.-]*(?:token|secret|passw(?:or)?d|api[_-]?key|access[_-]?key|private[_-]?key)[\"']?"
        r"\s*[:=]\s*[\"']?(?=[A-Za-z_\-+/]*\d)[A-Za-z0-9+/_\-]{16,}", re.IGNORECASE)),
)


def credential_rules(text: str) -> list[str]:
    """Names of the credential rules text matches, in rule order. Never returns the match."""
    return [name for name, pattern in CREDENTIAL_RULES if pattern.search(text)]


# --- errors -----------------------------------------------------------------------------------

class RegistryError(Exception):
    """Base of every registry failure. code is stable; the message never quotes input values."""
    code = "registry_error"


class InvalidPathError(RegistryError):
    code = "invalid_path"


class RegistryNotFoundError(RegistryError):
    code = "missing_database"


class SchemaError(RegistryError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


class ConfigurationError(RegistryError):
    code = "invalid_configuration"


class ConflictError(RegistryError):
    code = "conflict"


class ConstraintError(RegistryError):
    code = "constraint_violation"


class RegistryBusyError(RegistryError):
    code = "busy"


class StorageError(RegistryError):
    code = "storage_error"


class MalformedRequestError(RegistryError):
    code = "malformed_request"


# --- snapshots, requests, results -------------------------------------------------------------

@dataclass(frozen=True)
class ProviderSnapshot:
    id: str
    name: str
    enabled: bool


@dataclass(frozen=True)
class ModelPolicySnapshot:
    id: str
    provider_id: str
    kind: str
    enabled: bool
    declared_models: tuple[str, ...]


@dataclass(frozen=True)
class Grant:
    """A capability or permission granted to a conduit; enabled is the referenced row's flag."""
    id: str
    enabled: bool


@dataclass(frozen=True)
class SkillGrant:
    id: str
    version: str
    integrity_sha256: str
    enabled: bool


@dataclass(frozen=True)
class ConduitSnapshot:
    """One conduit as read in a single transaction. invocation is declarative; nothing runs it."""
    id: str
    name: str
    enabled: bool
    provider_id: str
    model_policy_id: str
    provider: ProviderSnapshot | None
    model_policy: ModelPolicySnapshot | None
    executable: str
    invocation: tuple[str, ...]
    capabilities: tuple[Grant, ...]
    permissions: tuple[Grant, ...]
    skills: tuple[SkillGrant, ...]


@dataclass(frozen=True)
class SkillRequirement:
    id: str
    version: str
    integrity_sha256: str


@dataclass(frozen=True)
class MatchRequest:
    """What a job needs. Actor and revision context come from a trusted caller, never from a
    conduit's name; approves_revision requires all of it."""
    required_capabilities: tuple[str, ...]
    required_permissions: tuple[str, ...]
    required_skills: tuple[SkillRequirement, ...] = ()
    actor_id: str | None = None
    revision_sha: str | None = None
    authored_by: tuple[str, ...] = ()
    approves_revision: bool = False


@dataclass(frozen=True)
class MatchResult:
    eligible: bool
    reasons: tuple[str, ...]


# --- matching ---------------------------------------------------------------------------------

def model_policy_problem(kind: object, models: object) -> str | None:
    """Why a policy's kind and declared models are not a complete policy, or None if they are."""
    if kind not in POLICY_KINDS:
        return "unknown model policy kind"
    if not isinstance(models, (tuple, list)):
        return "declared models are not a list"
    if any(not isinstance(m, str) or not IDENTIFIER.fullmatch(m) for m in models):
        return "a declared model id is not a lowercase identifier"
    if len(set(models)) != len(models):
        return "a declared model id repeats"
    if kind == "fixed" and len(models) != 1:
        return "a fixed policy declares exactly one model"
    if kind == "allow_list" and not models:
        return "an allow_list policy declares at least one model"
    if kind == "auto" and models:
        return "an auto policy declares no models"
    return None


def _identifiers(value: object, pattern: re.Pattern[str], allow_empty: bool) -> bool:
    return (isinstance(value, tuple) and (allow_empty or bool(value))
            and all(isinstance(item, str) and pattern.fullmatch(item) for item in value))


def _request_valid(request: object) -> bool:
    if not isinstance(request, MatchRequest):
        return False
    skills = request.required_skills
    return (_identifiers(request.required_capabilities, IDENTIFIER, False)
            and _identifiers(request.required_permissions, IDENTIFIER, False)
            and isinstance(skills, tuple)
            and all(isinstance(s, SkillRequirement) and isinstance(s.id, str) and IDENTIFIER.fullmatch(s.id)
                    and isinstance(s.version, str) and SKILL_VERSION.fullmatch(s.version)
                    and isinstance(s.integrity_sha256, str) and SHA256_HEX.fullmatch(s.integrity_sha256)
                    for s in skills)
            and (request.actor_id is None or (isinstance(request.actor_id, str)
                                              and bool(ACTOR.fullmatch(request.actor_id))))
            and (request.revision_sha is None or (isinstance(request.revision_sha, str)
                                                  and bool(REVISION.fullmatch(request.revision_sha))))
            and _identifiers(request.authored_by, ACTOR, True)
            and type(request.approves_revision) is bool)


def match_conduit(conduit: ConduitSnapshot | None, request: MatchRequest) -> MatchResult:
    """Deny by default. An absent snapshot is only unknown_conduit; an invalid request is only
    invalid_request; otherwise every applicable reason is returned, sorted. A required grant whose
    capability, permission or skill is disabled is disabled_configuration; a skill matches only
    with the exact id, version and integrity."""
    if not isinstance(conduit, ConduitSnapshot):
        return MatchResult(False, ("unknown_conduit",))
    if not _request_valid(request):
        return MatchResult(False, ("invalid_request",))
    reasons: set[str] = set()
    if not conduit.enabled:
        reasons.add("disabled_configuration")
    provider = conduit.provider
    if provider is None or not provider.enabled:
        reasons.add("disabled_configuration")
    elif provider.id != conduit.provider_id:
        reasons.add("invalid_model_policy")
    policy = conduit.model_policy
    if policy is None:
        reasons.add("invalid_model_policy")
    else:
        if not policy.enabled:
            reasons.add("disabled_configuration")
        if (policy.id != conduit.model_policy_id or policy.provider_id != conduit.provider_id
                or model_policy_problem(policy.kind, policy.declared_models) is not None):
            reasons.add("invalid_model_policy")

    for required, granted, missing in (
            (request.required_capabilities, conduit.capabilities, "missing_capability"),
            (request.required_permissions, conduit.permissions, "missing_permission")):
        by_id = {grant.id: grant for grant in granted}
        for wanted in required:
            grant = by_id.get(wanted)
            if grant is None:
                reasons.add(missing)
            elif not grant.enabled:
                reasons.add("disabled_configuration")
    skills = {(skill.id, skill.version): skill for skill in conduit.skills}
    for wanted in request.required_skills:
        skill = skills.get((wanted.id, wanted.version))
        if skill is None or skill.integrity_sha256 != wanted.integrity_sha256:
            reasons.add("missing_skill")
        elif not skill.enabled:
            reasons.add("disabled_configuration")

    if request.approves_revision:
        if request.actor_id is None or request.revision_sha is None or not request.authored_by:
            reasons.add("approval_context_missing")
        elif request.actor_id.casefold() in {author.casefold() for author in request.authored_by}:
            reasons.add("self_approval")
    return MatchResult(not reasons, tuple(sorted(reasons)))


REQUEST_KEYS = {"capabilities", "permissions", "skills", "actor_id", "revision_sha", "authored_by",
                "approves_revision"}
SKILL_REQUIREMENT_KEYS = {"id", "version", "integrity_sha256"}


def request_from_json(document: Any) -> MatchRequest:
    """Build a MatchRequest from its JSON form. Structural problems (wrong JSON types, unknown or
    missing keys) raise MalformedRequestError; values are judged by match_conduit, which turns an
    empty or ill-formed requirement into invalid_request."""
    if not isinstance(document, dict):
        raise MalformedRequestError("the request is not a JSON object")
    unknown = set(document) - REQUEST_KEYS
    if unknown:
        raise MalformedRequestError(f"the request has unknown keys: {', '.join(sorted(unknown))}")
    for key in ("capabilities", "permissions"):
        if key not in document:
            raise MalformedRequestError(f"the request has no {key} list")

    def strings(key: str) -> tuple[str, ...]:
        value = document.get(key, [])
        if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
            raise MalformedRequestError(f"{key} is not a list of strings")
        return tuple(value)

    skills = document.get("skills", [])
    if not isinstance(skills, list):
        raise MalformedRequestError("skills is not a list")
    requirements = []
    for skill in skills:
        if (not isinstance(skill, dict) or set(skill) != SKILL_REQUIREMENT_KEYS
                or not all(isinstance(value, str) for value in skill.values())):
            raise MalformedRequestError("each skill is an object of id, version and integrity_sha256 strings")
        requirements.append(SkillRequirement(skill["id"], skill["version"], skill["integrity_sha256"]))
    for key in ("actor_id", "revision_sha"):
        if document.get(key) is not None and not isinstance(document[key], str):
            raise MalformedRequestError(f"{key} is not a string or null")
    if not isinstance(document.get("approves_revision", False), bool):
        raise MalformedRequestError("approves_revision is not a boolean")
    return MatchRequest(
        required_capabilities=strings("capabilities"),
        required_permissions=strings("permissions"),
        required_skills=tuple(requirements),
        actor_id=document.get("actor_id"),
        revision_sha=document.get("revision_sha"),
        authored_by=strings("authored_by"),
        approves_revision=document.get("approves_revision", False),
    )


# --- schema -----------------------------------------------------------------------------------

def _identifier_check(column: str) -> str:
    return (f"typeof({column}) = 'text' AND length({column}) BETWEEN 1 AND 64"
            f" AND {column} GLOB '[a-z0-9]*' AND {column} NOT GLOB '*[^a-z0-9._-]*'")


def _flag_check(column: str) -> str:
    return f"typeof({column}) = 'integer' AND {column} IN (0, 1)"


def _name_check(column: str) -> str:
    return f"typeof({column}) = 'text' AND length(trim({column})) > 0 AND length({column}) <= {MAX_NAME}"


RESTRICT = "ON DELETE RESTRICT ON UPDATE RESTRICT"

SCHEMA_V1 = (
    f"""CREATE TABLE providers (
        id TEXT PRIMARY KEY NOT NULL CHECK ({_identifier_check('id')}),
        name TEXT NOT NULL CHECK ({_name_check('name')}),
        enabled INTEGER NOT NULL CHECK ({_flag_check('enabled')})
    )""",
    f"""CREATE TABLE model_policies (
        id TEXT PRIMARY KEY NOT NULL CHECK ({_identifier_check('id')}),
        provider_id TEXT NOT NULL REFERENCES providers (id) {RESTRICT},
        kind TEXT NOT NULL CHECK (kind IN ('fixed', 'allow_list', 'auto')),
        enabled INTEGER NOT NULL CHECK ({_flag_check('enabled')}),
        UNIQUE (id, provider_id)
    )""",
    f"""CREATE TABLE model_policy_models (
        model_policy_id TEXT NOT NULL REFERENCES model_policies (id) {RESTRICT},
        model_id TEXT NOT NULL CHECK ({_identifier_check('model_id')}),
        PRIMARY KEY (model_policy_id, model_id)
    )""",
    f"""CREATE TABLE capabilities (
        id TEXT PRIMARY KEY NOT NULL CHECK ({_identifier_check('id')}),
        name TEXT NOT NULL CHECK ({_name_check('name')}),
        enabled INTEGER NOT NULL CHECK ({_flag_check('enabled')})
    )""",
    f"""CREATE TABLE permissions (
        id TEXT PRIMARY KEY NOT NULL CHECK ({_identifier_check('id')}),
        name TEXT NOT NULL CHECK ({_name_check('name')}),
        enabled INTEGER NOT NULL CHECK ({_flag_check('enabled')})
    )""",
    f"""CREATE TABLE skills (
        id TEXT NOT NULL CHECK ({_identifier_check('id')}),
        version TEXT NOT NULL CHECK (typeof(version) = 'text' AND length(version) BETWEEN 1 AND 64
            AND version GLOB '[a-z0-9]*' AND version NOT GLOB '*[^a-z0-9.+-]*'),
        name TEXT NOT NULL CHECK ({_name_check('name')}),
        integrity_sha256 TEXT NOT NULL CHECK (typeof(integrity_sha256) = 'text'
            AND length(integrity_sha256) = 64 AND integrity_sha256 NOT GLOB '*[^0-9a-f]*'),
        enabled INTEGER NOT NULL CHECK ({_flag_check('enabled')}),
        PRIMARY KEY (id, version)
    )""",
    f"""CREATE TABLE conduits (
        id TEXT PRIMARY KEY NOT NULL CHECK ({_identifier_check('id')}),
        name TEXT NOT NULL CHECK ({_name_check('name')}),
        provider_id TEXT NOT NULL REFERENCES providers (id) {RESTRICT},
        model_policy_id TEXT NOT NULL,
        executable TEXT NOT NULL CHECK (typeof(executable) = 'text' AND length(executable) > 0),
        invocation_json TEXT NOT NULL CHECK (json_valid(invocation_json)
            AND json_type(invocation_json) = 'array' AND json_array_length(invocation_json) > 0
            AND json_type(invocation_json, '$[0]') = 'text'
            AND json_extract(invocation_json, '$[0]') = executable),
        enabled INTEGER NOT NULL CHECK ({_flag_check('enabled')}),
        FOREIGN KEY (model_policy_id, provider_id) REFERENCES model_policies (id, provider_id) {RESTRICT}
    )""",
    f"""CREATE TABLE conduit_capabilities (
        conduit_id TEXT NOT NULL REFERENCES conduits (id) {RESTRICT},
        capability_id TEXT NOT NULL REFERENCES capabilities (id) {RESTRICT},
        PRIMARY KEY (conduit_id, capability_id)
    )""",
    f"""CREATE TABLE conduit_permissions (
        conduit_id TEXT NOT NULL REFERENCES conduits (id) {RESTRICT},
        permission_id TEXT NOT NULL REFERENCES permissions (id) {RESTRICT},
        PRIMARY KEY (conduit_id, permission_id)
    )""",
    f"""CREATE TABLE conduit_skills (
        conduit_id TEXT NOT NULL REFERENCES conduits (id) {RESTRICT},
        skill_id TEXT NOT NULL,
        skill_version TEXT NOT NULL,
        PRIMARY KEY (conduit_id, skill_id, skill_version),
        FOREIGN KEY (skill_id, skill_version) REFERENCES skills (id, version) {RESTRICT}
    )""",
)


# --- connections and transactions -------------------------------------------------------------

def _checked_path(database_path: Path | str) -> Path:
    if not isinstance(database_path, (str, Path)):
        raise InvalidPathError("the database path must be a filesystem path")
    path = Path(database_path)
    if not path.is_absolute():
        raise InvalidPathError("the database path must be absolute")
    resolved = path.resolve()
    root = CHECKOUT_ROOT.resolve()
    if resolved == root or root in resolved.parents:
        raise InvalidPathError("the database path must be outside the repository checkout")
    if resolved.is_dir():
        raise InvalidPathError("the database path is a directory")
    if not resolved.parent.is_dir():
        raise InvalidPathError("the database directory does not exist")
    return resolved


def _is_busy(error: sqlite3.Error) -> bool:
    # sqlite_errorcode is the extended code (SQLITE_BUSY_SNAPSHOT and the like); its low byte is
    # the primary code. No message matching: an unrelated error must not read as lock contention.
    code = getattr(error, "sqlite_errorcode", None)
    return isinstance(code, int) and code & 0xFF in (sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED)


@contextlib.contextmanager
def _storage_errors() -> Iterator[None]:
    """Translate sqlite3 failures into registry errors. SQLite's messages name constraints and
    tables, never bound values."""
    try:
        yield
    except sqlite3.IntegrityError as error:
        raise ConstraintError(f"a registry constraint refused the change: {error}") from error
    except sqlite3.OperationalError as error:
        if _is_busy(error):
            raise RegistryBusyError(f"the registry stayed locked for {BUSY_TIMEOUT_SECONDS:g}s") from error
        raise StorageError(f"the registry could not be used: {error}") from error
    except sqlite3.Error as error:
        raise StorageError(f"the registry could not be used: {error}") from error


def _connect(path: Path, mode: str) -> sqlite3.Connection:
    """mode is SQLite's URI mode: rwc (migrate may create), rw (writes) or ro (reads)."""
    connection = sqlite3.connect(f"file:{quote(str(path))}?mode={mode}", uri=True,
                                 timeout=BUSY_TIMEOUT_SECONDS, isolation_level=None)
    try:
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute(f"PRAGMA busy_timeout = {int(BUSY_TIMEOUT_SECONDS * 1000)}")
    except BaseException:
        connection.close()
        raise
    return connection


def _user_version(connection: sqlite3.Connection) -> int:
    return int(connection.execute("PRAGMA user_version").fetchone()[0])


def _require_schema(connection: sqlite3.Connection) -> None:
    version = _user_version(connection)
    if version == 0:
        raise SchemaError("schema_missing", "the database has no registry schema; run migrate first")
    if version != SCHEMA_VERSION:
        raise SchemaError("unsupported_schema",
                          f"schema version {version} is not supported (this code reads {SCHEMA_VERSION})")


@contextlib.contextmanager
def _transaction(path: Path, mode: str, begin: str) -> Iterator[sqlite3.Connection]:
    with _storage_errors():
        connection = _connect(path, mode)
        try:
            connection.execute(begin)
            try:
                yield connection
            except BaseException:
                if connection.in_transaction:
                    connection.execute("ROLLBACK")
                raise
            connection.execute("COMMIT")
        finally:
            connection.close()


def _existing(database_path: Path | str) -> Path:
    path = _checked_path(database_path)
    if not path.is_file():
        raise RegistryNotFoundError("the registry database does not exist")
    return path


@contextlib.contextmanager
def admin_transaction(database_path: Path) -> Iterator[sqlite3.Connection]:
    """A write transaction on an existing version-1 registry, for operator edits and tests:
    foreign keys on, BEGIN IMMEDIATE, committed on success and rolled back on any exception.
    Constraint violations raise ConstraintError."""
    path = _existing(database_path)
    with _transaction(path, "rw", "BEGIN IMMEDIATE") as connection:
        _require_schema(connection)
        yield connection


def migrate(database_path: Path) -> int:
    """Create or upgrade the registry schema and return its version. A new or empty file becomes
    version 1 in one transaction; version 1 is returned unchanged; a newer version, or an
    unversioned file that already holds tables, is refused without any change."""
    path = _checked_path(database_path)
    with _transaction(path, "rwc", "BEGIN IMMEDIATE") as connection:
        version = _user_version(connection)
        if version == SCHEMA_VERSION:
            return SCHEMA_VERSION
        if version != 0:
            raise SchemaError("unsupported_schema",
                              f"schema version {version} is not supported (this code writes {SCHEMA_VERSION});"
                              " refusing to touch it")
        if connection.execute("SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'").fetchone()[0]:
            raise SchemaError("unsupported_schema",
                              "an unversioned database already holds tables; refusing to migrate it")
        for statement in SCHEMA_V1:
            connection.execute(statement)
        connection.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
    return SCHEMA_VERSION


# --- configuration ----------------------------------------------------------------------------

SECTION_KEYS: dict[str, tuple[str, ...]] = {
    "providers": ("id", "name", "enabled"),
    "model_policies": ("id", "provider_id", "kind", "models", "enabled"),
    "capabilities": ("id", "name", "enabled"),
    "permissions": ("id", "name", "enabled"),
    "skills": ("id", "version", "name", "integrity_sha256", "enabled"),
    "conduits": ("id", "name", "provider_id", "model_policy_id", "executable", "invocation", "enabled",
                 "capabilities", "permissions", "skills"),
}


def _scan_strings(node: Any, where: str) -> None:
    if isinstance(node, str):
        rules = credential_rules(node)
        if rules:
            raise ConfigurationError(f"{where} looks like a credential ({', '.join(rules)}); "
                                     "credentials and their values never belong in the registry")
    elif isinstance(node, Mapping):
        for key, value in node.items():
            _scan_strings(key, f"{where} key")
            _scan_strings(value, f"{where}.{key}")
    elif isinstance(node, (list, tuple)):
        for index, value in enumerate(node):
            _scan_strings(value, f"{where}[{index}]")


def _text(value: Any, where: str) -> str:
    if not isinstance(value, str) or not value.strip() or len(value) > MAX_NAME \
            or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ConfigurationError(f"{where} must be a nonempty single-line name of at most {MAX_NAME} characters")
    return value


def _identifier(value: Any, where: str, pattern: re.Pattern[str] = IDENTIFIER) -> str:
    if not isinstance(value, str) or not pattern.fullmatch(value):
        raise ConfigurationError(f"{where} must be a lowercase identifier")
    return value


def _flag(value: Any, where: str) -> int:
    if type(value) is not bool:
        raise ConfigurationError(f"{where} must be true or false")
    return int(value)


def _argument(value: Any, where: str) -> str:
    if not isinstance(value, str) or not value or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ConfigurationError(f"{where} must be a nonempty string without control characters")
    return value


def _unique_ids(values: list[Any], where: str) -> None:
    if len(set(values)) != len(values):
        raise ConfigurationError(f"{where} repeats an entry")


@dataclass(frozen=True)
class _Plan:
    """A validated document as rows in dependency order, plus the sets owned by each parent."""
    rows: tuple[tuple[str, tuple[str, ...], tuple[Any, ...]], ...]
    owned: tuple[tuple[str, str, tuple[str, ...], str, frozenset[tuple[Any, ...]]], ...]


def _validated(document: Any) -> _Plan:
    if not isinstance(document, Mapping):
        raise ConfigurationError("the configuration is not a JSON object")
    _scan_strings(document, "configuration")
    unknown = set(document) - set(SECTION_KEYS) - {"format"}
    if unknown:
        raise ConfigurationError(f"the configuration has unknown keys: {', '.join(sorted(unknown))}")
    if document.get("format") != CONFIG_FORMAT:
        raise ConfigurationError(f"format must be {CONFIG_FORMAT}")

    sections: dict[str, list[Mapping[str, Any]]] = {}
    for section, keys in SECTION_KEYS.items():
        entries = document.get(section, [])
        if not isinstance(entries, list):
            raise ConfigurationError(f"{section} must be a list")
        for index, entry in enumerate(entries):
            if not isinstance(entry, Mapping) or set(entry) != set(keys):
                raise ConfigurationError(f"{section}[{index}] must be an object with exactly: {', '.join(keys)}")
        sections[section] = entries

    rows: list[tuple[str, tuple[str, ...], tuple[Any, ...]]] = []
    owned: list[tuple[str, str, tuple[str, ...], str, frozenset[tuple[Any, ...]]]] = []

    def simple(section: str) -> set[str]:
        ids = []
        for index, entry in enumerate(sections[section]):
            where = f"{section}[{index}]"
            ids.append(_identifier(entry["id"], f"{where}.id"))
            rows.append((section, ("id",), (entry["id"], _text(entry["name"], f"{where}.name"),
                                            _flag(entry["enabled"], f"{where}.enabled"))))
        _unique_ids(ids, f"{section} ids")
        return set(ids)

    providers = simple("providers")
    policies: dict[str, str] = {}
    for index, entry in enumerate(sections["model_policies"]):
        where = f"model_policies[{index}]"
        policy_id = _identifier(entry["id"], f"{where}.id")
        if policy_id in policies:
            raise ConfigurationError("model_policies ids repeats an entry")
        if _identifier(entry["provider_id"], f"{where}.provider_id") not in providers:
            raise ConfigurationError(f"{where}.provider_id names no provider in this configuration")
        problem = model_policy_problem(entry["kind"], entry["models"])
        if problem:
            raise ConfigurationError(f"{where} is not a complete model policy: {problem}")
        policies[policy_id] = entry["provider_id"]
        rows.append(("model_policies", ("id",),
                     (policy_id, entry["provider_id"], entry["kind"], _flag(entry["enabled"], f"{where}.enabled"))))
        owned.append(("model_policy_models", "model_policy_id", ("model_id",), policy_id,
                      frozenset((model,) for model in entry["models"])))
    capabilities = simple("capabilities")
    permissions = simple("permissions")
    skills: set[tuple[str, str]] = set()
    for index, entry in enumerate(sections["skills"]):
        where = f"skills[{index}]"
        key = (_identifier(entry["id"], f"{where}.id"), _identifier(entry["version"], f"{where}.version", SKILL_VERSION))
        if key in skills:
            raise ConfigurationError("skills (id, version) repeats an entry")
        if not isinstance(entry["integrity_sha256"], str) or not SHA256_HEX.fullmatch(entry["integrity_sha256"]):
            raise ConfigurationError(f"{where}.integrity_sha256 must be 64 lowercase hexadecimal characters")
        skills.add(key)
        rows.append(("skills", ("id", "version"), (*key, _text(entry["name"], f"{where}.name"),
                                                    entry["integrity_sha256"], _flag(entry["enabled"], f"{where}.enabled"))))

    conduit_ids: list[str] = []
    for index, entry in enumerate(sections["conduits"]):
        where = f"conduits[{index}]"
        conduit_id = _identifier(entry["id"], f"{where}.id")
        conduit_ids.append(conduit_id)
        provider_id = _identifier(entry["provider_id"], f"{where}.provider_id")
        if provider_id not in providers:
            raise ConfigurationError(f"{where}.provider_id names no provider in this configuration")
        policy_id = _identifier(entry["model_policy_id"], f"{where}.model_policy_id")
        if policy_id not in policies:
            raise ConfigurationError(f"{where}.model_policy_id names no model policy in this configuration")
        if policies[policy_id] != provider_id:
            raise ConfigurationError(f"{where}.model_policy_id belongs to another provider")
        executable = _argument(entry["executable"], f"{where}.executable")
        invocation = entry["invocation"]
        if not isinstance(invocation, list) or not invocation:
            raise ConfigurationError(f"{where}.invocation must be a nonempty argv list")
        for position, argument in enumerate(invocation):
            _argument(argument, f"{where}.invocation[{position}]")
        if invocation[0] != executable:
            raise ConfigurationError(f"{where}.invocation[0] must equal the executable")
        rows.append(("conduits", ("id",), (conduit_id, _text(entry["name"], f"{where}.name"), provider_id, policy_id,
                                           executable, json.dumps(invocation, separators=(",", ":")),
                                           _flag(entry["enabled"], f"{where}.enabled"))))
        for key, known, table, column in (("capabilities", capabilities, "conduit_capabilities", "capability_id"),
                                          ("permissions", permissions, "conduit_permissions", "permission_id")):
            grants = entry[key]
            if not isinstance(grants, list):
                raise ConfigurationError(f"{where}.{key} must be a list")
            for position, grant in enumerate(grants):
                if _identifier(grant, f"{where}.{key}[{position}]") not in known:
                    raise ConfigurationError(f"{where}.{key}[{position}] names nothing defined in this configuration")
            _unique_ids(grants, f"{where}.{key}")
            owned.append((table, "conduit_id", (column,), conduit_id, frozenset((grant,) for grant in grants)))
        skill_grants = entry["skills"]
        if not isinstance(skill_grants, list):
            raise ConfigurationError(f"{where}.skills must be a list")
        pairs = []
        for position, grant in enumerate(skill_grants):
            if not isinstance(grant, Mapping) or set(grant) != {"id", "version"}:
                raise ConfigurationError(f"{where}.skills[{position}] must be an object with exactly: id, version")
            pair = (_identifier(grant["id"], f"{where}.skills[{position}].id"),
                    _identifier(grant["version"], f"{where}.skills[{position}].version", SKILL_VERSION))
            if pair not in skills:
                raise ConfigurationError(f"{where}.skills[{position}] names no skill version in this configuration")
            pairs.append(pair)
        _unique_ids(pairs, f"{where}.skills")
        owned.append(("conduit_skills", "conduit_id", ("skill_id", "skill_version"), conduit_id, frozenset(pairs)))
    _unique_ids(conduit_ids, "conduits ids")
    return _Plan(tuple(rows), tuple(owned))


TABLE_COLUMNS: dict[str, tuple[str, ...]] = {
    "providers": ("id", "name", "enabled"),
    "model_policies": ("id", "provider_id", "kind", "enabled"),
    "capabilities": ("id", "name", "enabled"),
    "permissions": ("id", "name", "enabled"),
    "skills": ("id", "version", "name", "integrity_sha256", "enabled"),
    "conduits": ("id", "name", "provider_id", "model_policy_id", "executable", "invocation_json", "enabled"),
    "model_policy_models": ("model_policy_id", "model_id"),
    "conduit_capabilities": ("conduit_id", "capability_id"),
    "conduit_permissions": ("conduit_id", "permission_id"),
    "conduit_skills": ("conduit_id", "skill_id", "skill_version"),
}


def _insert_row(connection: sqlite3.Connection, table: str, values: tuple[Any, ...]) -> None:
    columns = TABLE_COLUMNS[table]
    connection.execute(f"INSERT INTO {table} ({', '.join(columns)}) VALUES ({', '.join('?' * len(columns))})",
                       values)


def _normalised(table: str, row: tuple[Any, ...]) -> tuple[Any, ...]:
    if table != "conduits":
        return tuple(row)
    try:
        invocation = json.loads(row[5])
    except (TypeError, ValueError):
        invocation = None
    return (*row[:5], invocation, row[6])


def _apply(connection: sqlite3.Connection, plan: _Plan) -> None:
    created: set[tuple[str, Any]] = set()
    for table, key_columns, values in plan.rows:
        columns = TABLE_COLUMNS[table]
        key = values[:len(key_columns)]
        where = " AND ".join(f"{column} = ?" for column in key_columns)
        existing = connection.execute(f"SELECT {', '.join(columns)} FROM {table} WHERE {where}", key).fetchone()
        if existing is None:
            _insert_row(connection, table, values)
            created.add((table, key[0]))
        elif _normalised(table, existing) != _normalised(table, values):
            raise ConflictError(f"{table} {'/'.join(key)} already exists with different configuration; "
                                "nothing was changed")
    parents = {"model_policy_models": "model_policies", "conduit_capabilities": "conduits",
               "conduit_permissions": "conduits", "conduit_skills": "conduits"}
    for table, parent_column, columns, parent_id, wanted in plan.owned:
        if (parents[table], parent_id) in created:
            for values in sorted(wanted):
                _insert_row(connection, table, (parent_id, *values))
            continue
        have = frozenset(connection.execute(
            f"SELECT {', '.join(columns)} FROM {table} WHERE {parent_column} = ?", (parent_id,)).fetchall())
        if have != wanted:
            raise ConflictError(f"{table} for {parent_id} already exists with different entries; nothing was changed")


def apply_configuration(database_path: Path, document: Mapping[str, Any]) -> None:
    """Validate a complete configuration document and insert it in one transaction. Identical
    existing rows are left alone; any difference is a ConflictError and nothing is written."""
    plan = _validated(document)
    with admin_transaction(database_path) as connection:
        _apply(connection, plan)


def example_configuration() -> dict[str, Any]:
    """The committed example fixture with each skill's integrity derived from its procedure file."""
    try:
        document = json.loads(EXAMPLES_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ConfigurationError("the example configuration could not be read") from error
    base = EXAMPLES_PATH.parent.resolve()
    for index, skill in enumerate(document.get("skills", [])):
        procedure = skill.pop("procedure", None)
        source = (base / procedure).resolve() if isinstance(procedure, str) else None
        if source is None or base not in source.parents or not source.is_file():
            raise ConfigurationError(f"skills[{index}].procedure must name a file beside the examples")
        skill["integrity_sha256"] = hashlib.sha256(source.read_bytes()).hexdigest()
    return document


def seed_examples(database_path: Path) -> None:
    """Insert the example fixture (Charlie and Chase) transactionally; repeating it is a no-op."""
    apply_configuration(database_path, example_configuration())


# --- reads ------------------------------------------------------------------------------------

def _grants(connection: sqlite3.Connection, table: str, column: str, target: str,
            conduit_id: str) -> tuple[Grant, ...]:
    return tuple(Grant(row[0], row[1] == 1) for row in connection.execute(
        f"SELECT g.{column}, t.enabled FROM {table} g JOIN {target} t ON t.id = g.{column}"
        f" WHERE g.conduit_id = ? ORDER BY g.{column}", (conduit_id,)))


def _read_conduit(connection: sqlite3.Connection, conduit_id: str) -> ConduitSnapshot | None:
    row = connection.execute(
        "SELECT id, name, enabled, provider_id, model_policy_id, executable, invocation_json"
        " FROM conduits WHERE id = ?", (conduit_id,)).fetchone()
    if row is None:
        return None
    provider_row = connection.execute("SELECT id, name, enabled FROM providers WHERE id = ?", (row[3],)).fetchone()
    policy_row = connection.execute("SELECT id, provider_id, kind, enabled FROM model_policies WHERE id = ?",
                                    (row[4],)).fetchone()
    policy = None
    if policy_row is not None:
        models = tuple(m[0] for m in connection.execute(
            "SELECT model_id FROM model_policy_models WHERE model_policy_id = ? ORDER BY model_id", (row[4],)))
        policy = ModelPolicySnapshot(policy_row[0], policy_row[1], policy_row[2], policy_row[3] == 1, models)
    try:
        invocation = json.loads(row[6])
    except ValueError as error:
        raise StorageError("a stored conduit invocation is not JSON") from error
    if not isinstance(invocation, list) or not all(isinstance(argument, str) for argument in invocation):
        raise StorageError("a stored conduit invocation is not a list of strings")
    skills = tuple(SkillGrant(s[0], s[1], s[2], s[3] == 1) for s in connection.execute(
        "SELECT g.skill_id, g.skill_version, s.integrity_sha256, s.enabled FROM conduit_skills g"
        " JOIN skills s ON s.id = g.skill_id AND s.version = g.skill_version"
        " WHERE g.conduit_id = ? ORDER BY g.skill_id, g.skill_version", (conduit_id,)))
    return ConduitSnapshot(
        id=row[0], name=row[1], enabled=row[2] == 1, provider_id=row[3], model_policy_id=row[4],
        provider=None if provider_row is None else ProviderSnapshot(provider_row[0], provider_row[1],
                                                                    provider_row[2] == 1),
        model_policy=policy, executable=row[5], invocation=tuple(invocation),
        capabilities=_grants(connection, "conduit_capabilities", "capability_id", "capabilities", conduit_id),
        permissions=_grants(connection, "conduit_permissions", "permission_id", "permissions", conduit_id),
        skills=skills,
    )


def load_conduit(database_path: Path, conduit_id: str) -> ConduitSnapshot | None:
    """An immutable snapshot of one conduit, with enabled states and explicit grants, read in one
    read-only transaction; None when no such conduit exists. A missing file or a schema other
    than version 1 is refused. Policy completeness is not repaired here; match_conduit revalidates
    it and denies invalid_model_policy."""
    path = _existing(database_path)
    with _transaction(path, "ro", "BEGIN") as connection:
        _require_schema(connection)
        if not isinstance(conduit_id, str) or not IDENTIFIER.fullmatch(conduit_id):
            return None
        return _read_conduit(connection, conduit_id)
