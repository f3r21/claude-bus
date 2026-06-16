"""
Storage and operations for claude-bus.

All bus state lives in one SQLite file (WAL mode). Independent server processes
-- one per Claude Code session for the stdio transport -- coordinate through
that file. The HTTP transport uses a single process but the same schema, so a
local stdio bus and a remote HTTP bus are interchangeable backends.

The functions here are pure storage operations: identity (``name`` / ``sender``)
is always passed in explicitly so the module stays stateless and testable. The
binding of an identity to a session lives in the server layer.

The DB path is taken from ``$BUS_DB``, defaulting to ``~/.claude-bus/bus.db``.

Schema version (``PRAGMA user_version``):
  v2 (this file) replaces the per-row ``messages.read`` flag with a per-agent
  read cursor (``agents.last_read_id``) plus a ``deliveries`` receipts table, so
  a broadcast is delivered to every recipient independently and late joiners
  still receive earlier broadcasts. It adds CAS/versioning to ``state`` and an
  advisory ``claims`` table for soft file locks.
"""

import fnmatch
import json
import logging
import os
import sqlite3
import time
from pathlib import Path
from typing import Optional

logger = logging.getLogger("claude_bus")

SCHEMA_VERSION = 2

# A message addressed to this recipient is a broadcast everyone (except the
# sender) receives.
BROADCAST = "all"


def db_path() -> Path:
    return Path(os.environ.get("BUS_DB", Path.home() / ".claude-bus" / "bus.db"))


def _connect() -> sqlite3.Connection:
    p = db_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(p, timeout=10)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    conn.row_factory = sqlite3.Row
    return conn


def _has_column(c: sqlite3.Connection, table: str, column: str) -> bool:
    rows = c.execute(f"PRAGMA table_info({table})").fetchall()
    return any(r["name"] == column for r in rows)


def _create_v2(c: sqlite3.Connection) -> None:
    """Create every v2 table if missing (safe on fresh and migrated DBs)."""
    c.execute(
        "CREATE TABLE IF NOT EXISTS agents("
        "name TEXT PRIMARY KEY, role TEXT, owns TEXT, "
        "last_seen REAL, last_read_id INTEGER DEFAULT 0)"
    )
    c.execute(
        "CREATE TABLE IF NOT EXISTS messages("
        "id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, sender TEXT, "
        "recipient TEXT, content TEXT, reply_to INTEGER)"
    )
    c.execute(
        "CREATE TABLE IF NOT EXISTS deliveries("
        "message_id INTEGER, recipient TEXT, read INTEGER DEFAULT 0, read_ts REAL, "
        "PRIMARY KEY(message_id, recipient))"
    )
    c.execute(
        "CREATE TABLE IF NOT EXISTS state("
        "key TEXT PRIMARY KEY, value TEXT, version INTEGER DEFAULT 1, "
        "updated_by TEXT, ts REAL)"
    )
    c.execute(
        "CREATE TABLE IF NOT EXISTS claims("
        "path TEXT PRIMARY KEY, owner TEXT, ts REAL, ttl REAL)"
    )


def _migrate_v1_to_v2(c: sqlite3.Connection) -> None:
    """Upgrade a v0.1 database in place.

    ``state`` is the durable, valuable data and is preserved (its rows gain
    ``version = 1``). The message read-model changed incompatibly, so the old
    ``messages`` table is dropped and recreated empty in the v2 shape; existing
    agents keep their identity but start at ``last_read_id = 0``. Coordination
    messages are ephemeral, so dropping them is an accepted, documented loss.
    """
    logger.info("claude-bus: migrating database to schema v%d", SCHEMA_VERSION)
    if not _has_column(c, "state", "version"):
        c.execute("ALTER TABLE state ADD COLUMN version INTEGER DEFAULT 1")
    if not _has_column(c, "agents", "owns"):
        c.execute("ALTER TABLE agents ADD COLUMN owns TEXT")
    if not _has_column(c, "agents", "last_read_id"):
        c.execute("ALTER TABLE agents ADD COLUMN last_read_id INTEGER DEFAULT 0")
    # Read-model changed: reset messages (recreated in v2 shape by _create_v2).
    c.execute("DROP TABLE IF EXISTS messages")


def init() -> None:
    """Create or migrate the schema. Idempotent; safe to call on every start."""
    with _connect() as c:
        uv = c.execute("PRAGMA user_version").fetchone()[0]
        if uv >= SCHEMA_VERSION:
            _create_v2(c)  # ensure all tables exist; no-op if already present
            return
        tables = {
            r["name"]
            for r in c.execute("SELECT name FROM sqlite_master WHERE type='table'")
        }
        is_v1 = "messages" in tables and _has_column(c, "messages", "read")
        if is_v1:
            _migrate_v1_to_v2(c)
        _create_v2(c)
        c.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")


def _heartbeat(
    c: sqlite3.Connection,
    name: str,
    role: str = "",
    owns_json: Optional[str] = None,
) -> None:
    """Upsert an agent's presence without disturbing its read cursor.

    ``role`` and ``owns`` are only overwritten when a non-empty value is given,
    so a bare heartbeat from ``send``/``inbox`` preserves what ``register`` set.
    """
    c.execute(
        "INSERT INTO agents(name, role, owns, last_seen, last_read_id) "
        "VALUES(?,?,?,?,0) "
        "ON CONFLICT(name) DO UPDATE SET "
        "role=CASE WHEN excluded.role != '' THEN excluded.role ELSE agents.role END, "
        "owns=CASE WHEN excluded.owns IS NOT NULL THEN excluded.owns ELSE agents.owns END, "
        "last_seen=excluded.last_seen",
        (name, role, owns_json, time.time()),
    )


def register(name: str, role: str = "", owns: Optional[list] = None) -> str:
    """Announce a session and optionally declare the file globs it owns."""
    owns_json = json.dumps(owns) if owns else None
    with _connect() as c:
        _heartbeat(c, name, role, owns_json)
    suffix = f" ({role})" if role else ""
    return f"registered '{name}'" + suffix


def _interests(name: str, owns: list, active_claims: list) -> list:
    """A session's footprint: its declared globs plus its live claim paths."""
    items = list(owns)
    items += [cl["path"] for cl in active_claims if cl["owner"] == name]
    return items


def _footprints_overlap(a_items: list, b_items: list) -> bool:
    """Advisory overlap: any pair where one entry matches the other as a glob."""
    for x in a_items:
        for y in b_items:
            if x == y or fnmatch.fnmatch(x, y) or fnmatch.fnmatch(y, x):
                return True
    return False


def agents(active_within: float = 180.0) -> list:
    """List sessions seen within ``active_within`` seconds.

    Each entry includes its declared ``owns`` globs and an ``overlaps`` list of
    other active sessions whose globs or live claims intersect -- an advisory
    early warning that two sessions may be touching the same files.
    """
    now = time.time()
    cutoff = now - active_within
    with _connect() as c:
        rows = c.execute(
            "SELECT name, role, owns, last_seen FROM agents "
            "WHERE last_seen >= ? ORDER BY last_seen DESC",
            (cutoff,),
        ).fetchall()
        claim_rows = c.execute("SELECT path, owner, ts, ttl FROM claims").fetchall()

    active_claims = [r for r in claim_rows if r["ts"] + r["ttl"] >= now]
    parsed = [
        {
            "name": r["name"],
            "role": r["role"],
            "owns": json.loads(r["owns"]) if r["owns"] else [],
            "seconds_ago": round(now - r["last_seen"], 1),
        }
        for r in rows
    ]
    footprints = {
        a["name"]: _interests(a["name"], a["owns"], active_claims) for a in parsed
    }
    for a in parsed:
        overlaps = [
            b["name"]
            for b in parsed
            if b["name"] != a["name"]
            and _footprints_overlap(footprints[a["name"]], footprints[b["name"]])
        ]
        a["overlaps"] = sorted(overlaps)
    return parsed


def send(sender: str, to: str, content: str, reply_to: Optional[int] = None) -> int:
    """Append a message and return its id (use the id as ``reply_to`` to thread)."""
    with _connect() as c:
        cur = c.execute(
            "INSERT INTO messages(ts, sender, recipient, content, reply_to) "
            "VALUES(?,?,?,?,?)",
            (time.time(), sender, to, content, reply_to),
        )
        msg_id = cur.lastrowid
        _heartbeat(c, sender)
    return int(msg_id)


def _visible(c: sqlite3.Connection, name: str, cursor: int) -> list:
    return c.execute(
        "SELECT id, ts, sender, recipient, content, reply_to FROM messages "
        "WHERE id > ? AND (recipient = ? OR recipient = ?) AND sender != ? "
        "ORDER BY id",
        (cursor, name, BROADCAST, name),
    ).fetchall()


def inbox(name: str, consume: bool = True, peek: bool = False) -> dict:
    """Return messages newer than this session's cursor.

    ``consume`` (default) advances the cursor past the current newest message
    and records read receipts; ``peek=True`` returns the same messages without
    advancing or recording, so history can be re-read. The returned
    ``pending_count`` is how many messages remain unread after the call.
    """
    if peek:
        consume = False
    with _connect() as c:
        row = c.execute(
            "SELECT last_read_id FROM agents WHERE name = ?", (name,)
        ).fetchone()
        cursor = row["last_read_id"] if row else 0
        rows = _visible(c, name, cursor)
        _heartbeat(c, name)  # also ensures the agent row exists

        if consume:
            top = c.execute("SELECT MAX(id) AS m FROM messages").fetchone()["m"]
            effective = top if top is not None else cursor
            c.execute(
                "UPDATE agents SET last_read_id = ? WHERE name = ?", (effective, name)
            )
            now = time.time()
            for r in rows:
                c.execute(
                    "INSERT INTO deliveries(message_id, recipient, read, read_ts) "
                    "VALUES(?,?,1,?) "
                    "ON CONFLICT(message_id, recipient) "
                    "DO UPDATE SET read=1, read_ts=excluded.read_ts",
                    (r["id"], name, now),
                )
        else:
            effective = cursor

        pending = c.execute(
            "SELECT COUNT(*) AS n FROM messages "
            "WHERE id > ? AND (recipient = ? OR recipient = ?) AND sender != ?",
            (effective, name, BROADCAST, name),
        ).fetchone()["n"]

    messages = [
        {
            "id": r["id"],
            "from": r["sender"],
            "to": r["recipient"],
            "content": r["content"],
            "reply_to": r["reply_to"],
        }
        for r in rows
    ]
    return {"messages": messages, "pending_count": pending}


def message_status(message_id: int) -> dict:
    """Show which recipients have read a message and when."""
    with _connect() as c:
        msg = c.execute(
            "SELECT id, sender, recipient FROM messages WHERE id = ?", (message_id,)
        ).fetchone()
        if msg is None:
            raise ValueError(f"no message with id {message_id}")
        readers = c.execute(
            "SELECT recipient, read_ts FROM deliveries "
            "WHERE message_id = ? AND read = 1 ORDER BY read_ts",
            (message_id,),
        ).fetchall()
    return {
        "message_id": msg["id"],
        "sender": msg["sender"],
        "recipient": msg["recipient"],
        "readers": [
            {"recipient": r["recipient"], "read_ts": r["read_ts"]} for r in readers
        ],
    }


def set_state(
    key: str,
    value: str,
    by: str = "",
    expected_version: Optional[int] = None,
    mode: str = "overwrite",
) -> int:
    """Write a shared key and return its new version.

    ``expected_version`` enables compare-and-set: if it does not match the
    current version the write is rejected (the error reports the current
    version so the caller can re-read and retry). ``mode='append'`` adds
    ``value`` as a new line instead of replacing. New keys start at version 1.
    """
    if mode not in ("overwrite", "append"):
        raise ValueError(f"unknown mode '{mode}' (use 'overwrite' or 'append')")
    with _connect() as c:
        row = c.execute(
            "SELECT value, version FROM state WHERE key = ?", (key,)
        ).fetchone()
        current_version = row["version"] if row else 0
        if expected_version is not None and expected_version != current_version:
            raise ValueError(
                f"stale write: expected_version {expected_version} != "
                f"current {current_version}; re-read '{key}' and retry"
            )
        if mode == "append" and row is not None and row["value"]:
            new_value = row["value"] + "\n" + value
        else:
            new_value = value
        new_version = current_version + 1
        c.execute(
            "INSERT INTO state(key, value, version, updated_by, ts) "
            "VALUES(?,?,?,?,?) "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value, "
            "version=excluded.version, updated_by=excluded.updated_by, ts=excluded.ts",
            (key, new_value, new_version, by, time.time()),
        )
    return new_version


def get_state(key: str = "") -> list:
    """Read one shared key, or every key if ``key`` is empty (values included)."""
    with _connect() as c:
        if key:
            rows = c.execute(
                "SELECT key, value, updated_by, version, ts FROM state WHERE key = ?",
                (key,),
            ).fetchall()
        else:
            rows = c.execute(
                "SELECT key, value, updated_by, version, ts FROM state ORDER BY key"
            ).fetchall()
    return [
        {
            "key": r["key"],
            "value": r["value"],
            "updated_by": r["updated_by"],
            "updated_at": r["ts"],
            "version": r["version"],
        }
        for r in rows
    ]


def list_state() -> list:
    """List state keys with metadata but without values (cheap discovery)."""
    with _connect() as c:
        rows = c.execute(
            "SELECT key, updated_by, version, ts FROM state ORDER BY key"
        ).fetchall()
    return [
        {
            "key": r["key"],
            "updated_by": r["updated_by"],
            "updated_at": r["ts"],
            "version": r["version"],
        }
        for r in rows
    ]


def claim(path: str, owner: str, ttl: float = 1800.0) -> str:
    """Place an advisory soft-lock on ``path`` for ``owner``.

    Fails if a non-expired claim by a different owner exists (the error names
    the holder and the remaining TTL). The current owner may refresh its own
    claim. Claims never block the filesystem; they only announce intent.
    """
    now = time.time()
    with _connect() as c:
        row = c.execute(
            "SELECT owner, ts, ttl FROM claims WHERE path = ?", (path,)
        ).fetchone()
        if row is not None:
            expires = row["ts"] + row["ttl"]
            if expires >= now and row["owner"] != owner:
                remaining = round(expires - now, 1)
                raise ValueError(
                    f"'{path}' is claimed by '{row['owner']}' "
                    f"for another {remaining}s"
                )
        c.execute(
            "INSERT INTO claims(path, owner, ts, ttl) VALUES(?,?,?,?) "
            "ON CONFLICT(path) DO UPDATE SET owner=excluded.owner, "
            "ts=excluded.ts, ttl=excluded.ttl",
            (path, owner, now, ttl),
        )
        _heartbeat(c, owner)
    return f"claimed '{path}' for {int(ttl)}s"


def release(path: str, owner: str) -> str:
    """Release a claim held by ``owner``."""
    with _connect() as c:
        row = c.execute("SELECT owner FROM claims WHERE path = ?", (path,)).fetchone()
        if row is None:
            return f"no claim on '{path}'"
        if row["owner"] != owner:
            raise ValueError(f"'{path}' is claimed by '{row['owner']}', not '{owner}'")
        c.execute("DELETE FROM claims WHERE path = ?", (path,))
        _heartbeat(c, owner)
    return f"released '{path}'"


def list_claims() -> list:
    """List active (non-expired) claims with their remaining TTL."""
    now = time.time()
    with _connect() as c:
        rows = c.execute(
            "SELECT path, owner, ts, ttl FROM claims ORDER BY path"
        ).fetchall()
    result = []
    for r in rows:
        remaining = r["ts"] + r["ttl"] - now
        if remaining >= 0:
            result.append(
                {
                    "path": r["path"],
                    "owner": r["owner"],
                    "ttl_remaining": round(remaining, 1),
                }
            )
    return result
