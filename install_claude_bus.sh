#!/usr/bin/env bash
# Self-contained local installer for claude-bus. Creates ~/claude-bus and runs setup.
# Usage:  bash install_claude_bus.sh   (or pass a target dir as $1)
#
# GENERATED FILE -- do not hand-edit the heredocs below. They embed a verbatim copy
# of the stdio source tree. Re-run `python scripts/gen_installer.py` after changing
# any embedded file (src/, hooks/, commands/, setup.sh) so the copy stays in sync.
set -euo pipefail
DEST="${1:-$HOME/claude-bus}"
mkdir -p "$DEST/src/claude_bus" "$DEST/hooks" "$DEST/commands"
echo "Scaffolding claude-bus into $DEST"
cat > "$DEST/src/claude_bus/__init__.py" <<'CBUS_EOF_0'
"""claude-bus: a shared message and state bus for multiple Claude Code sessions."""

__version__ = "0.2.0"
CBUS_EOF_0
cat > "$DEST/src/claude_bus/core.py" <<'CBUS_EOF_1'
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
CBUS_EOF_1
cat > "$DEST/src/claude_bus/server.py" <<'CBUS_EOF_2'
"""FastMCP server exposing the bus over stdio (one process per session).

Identity is bound to the session, not passed per call: the first ``register``
fixes this process's name in module-local state, and ``send`` / ``inbox`` /
``claim`` / ``release`` derive the actor from it. Because each stdio session runs
its own server process, this makes it impossible to act as another session.
Calling an identity-bound tool before ``register`` raises an actionable error.

The HTTP transport is a single process serving many clients, so this
process-local binding does not apply there -- see ``http_server.py``.
"""

from typing import Optional

from mcp.server.fastmcp import FastMCP

from . import core

core.init()

mcp = FastMCP("claude-bus")

# Process-local identity for this stdio session. Set by register(); read by the
# identity-bound tools below. Tests reset this between cases.
_identity: Optional[str] = None


def _require_identity() -> str:
    if _identity is None:
        raise ValueError(
            "register first: call register(name) to bind this session's identity"
        )
    return _identity


@mcp.tool()
def register(name: str, role: str = "", owns: Optional[list] = None) -> str:
    """Bind this session's identity and announce it on the bus.

    name: stable identifier for this session, e.g. 'backend' or 'frontend'.
    role: free-text description of what this session is responsible for.
    owns: optional list of path globs this session expects to edit, e.g.
          ['src/api/**', 'tests/api/**']; used to flag overlap with peers.
    """
    global _identity
    _identity = name
    return core.register(name, role, owns)


@mcp.tool()
def whoami() -> str:
    """Return this session's bound identity (or a note if not registered yet)."""
    return _identity if _identity is not None else "not registered (call register)"


@mcp.tool()
def agents(active_within: float = 180.0) -> list:
    """List sessions seen within the last `active_within` seconds, with overlaps."""
    return core.agents(active_within)


@mcp.tool()
def send(to: str, content: str, reply_to: Optional[int] = None) -> str:
    """Send a message. `to` is a peer name or 'all' to broadcast.

    Pass another message's id as `reply_to` to thread a reply. The sender is
    this session's bound identity.
    """
    sender = _require_identity()
    msg_id = core.send(sender, to, content, reply_to)
    return f"sent to '{to}' (id {msg_id})"


@mcp.tool()
def inbox(consume: bool = True, peek: bool = False) -> dict:
    """Pull messages newer than this session's read cursor.

    consume (default) advances the cursor and records read receipts; peek=True
    returns the same messages without consuming so history can be re-read.
    Returns {messages, pending_count}.
    """
    name = _require_identity()
    return core.inbox(name, consume=consume, peek=peek)


@mcp.tool()
def message_status(message_id: int) -> dict:
    """Show which recipients have read a message and when."""
    return core.message_status(message_id)


@mcp.tool()
def set_state(
    key: str,
    value: str,
    expected_version: Optional[int] = None,
    mode: str = "overwrite",
) -> str:
    """Write a shared key on the blackboard every session can read.

    Pass expected_version for compare-and-set (rejected if it does not match the
    current version, so you can re-read and retry). mode='append' adds value as
    a new line. Returns the new version.
    """
    by = _identity or ""
    version = core.set_state(key, value, by, expected_version, mode)
    return f"state['{key}'] set (version {version})"


@mcp.tool()
def get_state(key: str = "") -> list:
    """Read one shared key, or every key if `key` is empty (values included)."""
    return core.get_state(key)


@mcp.tool()
def list_state() -> list:
    """List shared keys with metadata but without values (cheap discovery)."""
    return core.list_state()


@mcp.tool()
def claim(path: str, ttl: float = 1800.0) -> str:
    """Place an advisory soft-lock on `path` so peers know you are editing it.

    Fails if another session holds a live claim. Advisory only -- it never
    blocks the filesystem.
    """
    owner = _require_identity()
    return core.claim(path, owner, ttl)


@mcp.tool()
def release(path: str) -> str:
    """Release a claim you hold."""
    owner = _require_identity()
    return core.release(path, owner)


@mcp.tool()
def list_claims() -> list:
    """List active (non-expired) file claims and their remaining TTL."""
    return core.list_claims()


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
CBUS_EOF_2
cat > "$DEST/bus_server.py" <<'CBUS_EOF_3'
#!/usr/bin/env python3
"""
Local entry point for the stdio bus server (used by setup.sh / the installer).
Runs the packaged server from the bundled src/ copy, so there is a single
implementation shared with the PyPI package and the HTTP/Docker build.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "src"))

from claude_bus.server import main  # noqa: E402

if __name__ == "__main__":
    main()
CBUS_EOF_3
cat > "$DEST/hooks/stop_bus.py" <<'CBUS_EOF_4'
#!/usr/bin/env python3
"""
Stop hook for claude-bus. Makes a session REACT to incoming messages: when it is
about to stop, if there are messages newer than its read cursor, the hook blocks
the stop and feeds them back, so the session keeps working instead of going idle.

Identity resolution (so the same script works as a local hook and as a plugin
hook): the session name is taken from the first CLI argument, else from $BUS_NAME.
If neither is set the hook is a silent no-op -- safe to enable globally, since a
session that never joined the bus has no name and nothing to pick up.

This runs as a standalone script with the system Python and does NOT import the
claude_bus package, so it talks to SQLite directly. It must stay in sync with the
delivery model in core.py: a per-agent cursor (agents.last_read_id) selects
unread messages; "consuming" them advances the cursor to MAX(messages.id) and
records receipts in the deliveries table.

Loop safety: the cursor is advanced here, so a second Stop finds nothing new and
the session is allowed to stop. The stop_hook_active flag is honored as well.
"""

import json
import os
import sqlite3
import sys
import time
from pathlib import Path

DB_PATH = Path(os.environ.get("BUS_DB", Path.home() / ".claude-bus" / "bus.db"))


def main() -> int:
    name = (sys.argv[1] if len(sys.argv) > 1 else "") or os.environ.get("BUS_NAME", "")
    if not name or not DB_PATH.exists():
        return 0

    try:
        payload = json.load(sys.stdin)
    except Exception:
        payload = {}
    if payload.get("stop_hook_active"):
        return 0

    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.execute("PRAGMA busy_timeout=5000")
    conn.row_factory = sqlite3.Row

    cursor_row = conn.execute(
        "SELECT last_read_id FROM agents WHERE name = ?", (name,)
    ).fetchone()
    cursor = cursor_row["last_read_id"] if cursor_row else 0

    rows = conn.execute(
        "SELECT id, sender, content FROM messages "
        "WHERE id > ? AND (recipient = ? OR recipient = 'all') AND sender != ? "
        "ORDER BY id",
        (cursor, name, name),
    ).fetchall()

    if not rows:
        conn.close()
        return 0

    now = time.time()
    top = conn.execute("SELECT MAX(id) AS m FROM messages").fetchone()["m"]
    new_cursor = top if top is not None else cursor
    conn.execute(
        "INSERT INTO agents(name, role, owns, last_seen, last_read_id) "
        "VALUES(?,'',NULL,?,?) "
        "ON CONFLICT(name) DO UPDATE SET "
        "last_read_id=excluded.last_read_id, last_seen=excluded.last_seen",
        (name, now, new_cursor),
    )
    for r in rows:
        conn.execute(
            "INSERT INTO deliveries(message_id, recipient, read, read_ts) "
            "VALUES(?,?,1,?) "
            "ON CONFLICT(message_id, recipient) DO UPDATE SET read=1, read_ts=excluded.read_ts",
            (r["id"], name, now),
        )
    conn.commit()
    conn.close()

    lines = [f"- from {r['sender']}: {r['content']}" for r in rows]
    reason = (
        f"You ({name}) have {len(rows)} new bus message(s):\n"
        + "\n".join(lines)
        + "\n\nHandle them, update shared state with set_state if relevant, "
        "reply with send if needed, then you may stop."
    )
    print(json.dumps({"decision": "block", "reason": reason}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
CBUS_EOF_4
cat > "$DEST/hooks/inject_state.py" <<'CBUS_EOF_5'
#!/usr/bin/env python3
"""
UserPromptSubmit hook for claude-bus. Injects current bus state as context every
time you send a prompt, so the session always knows who else is connected and
whether messages are waiting.

Identity: first CLI argument, else $BUS_NAME. No identity -> silent no-op.
For UserPromptSubmit, stdout (exit 0) is added to the model's context.

Runs standalone (no claude_bus import) and queries SQLite directly, so it must
stay in sync with core.py: "unread" means messages past the agent's read cursor
(agents.last_read_id), not a per-row read flag.
"""

import os
import sqlite3
import sys
import time
from pathlib import Path

DB_PATH = Path(os.environ.get("BUS_DB", Path.home() / ".claude-bus" / "bus.db"))


def main() -> int:
    name = (sys.argv[1] if len(sys.argv) > 1 else "") or os.environ.get("BUS_NAME", "")
    if not name or not DB_PATH.exists():
        return 0

    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.execute("PRAGMA busy_timeout=5000")
    conn.row_factory = sqlite3.Row

    cursor_row = conn.execute(
        "SELECT last_read_id FROM agents WHERE name = ?", (name,)
    ).fetchone()
    cursor = cursor_row["last_read_id"] if cursor_row else 0
    pending = conn.execute(
        "SELECT COUNT(*) AS n FROM messages "
        "WHERE id > ? AND (recipient = ? OR recipient = 'all') AND sender != ?",
        (cursor, name, name),
    ).fetchone()["n"]
    cutoff = time.time() - 180
    peers = conn.execute(
        "SELECT name FROM agents WHERE last_seen >= ? AND name != ? ORDER BY name",
        (cutoff, name),
    ).fetchall()
    conn.close()

    peer_names = ", ".join(p["name"] for p in peers) or "none"
    print(
        f"[claude-bus] you are '{name}'. Active peers: {peer_names}. "
        f"Unread messages for you: {pending}. "
        f"Use the bus tools (inbox, send, get_state, set_state) to coordinate."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
CBUS_EOF_5
cat > "$DEST/commands/bus.md" <<'CBUS_EOF_6'
---
argument-hint: "[nombre]  (vacio = revisar el bus)"
description: Unirse al bus o revisar mensajes (sesiones de Claude Code)
---
Bus de mensajes y estado compartido con otras sesiones de Claude Code.

Argumento recibido: "$ARGUMENTS"

CASO A -- viene un nombre (hay texto en el argumento):
  Esa es tu identidad. NOMBRE = primera palabra; ROL = el resto (si hay).
  1. register(NOMBRE, ROL)   -- anunciarte y fijar tu identidad en el bus
  2. agents()                -- ver quien mas esta conectado (y solapamientos)
  3. inbox()                 -- recoger mensajes que te esperan
  Confirma en UNA linea quien eres y quien mas esta en el bus.

CASO B -- el argumento esta vacio ("revisa el bus"):
  Usa tu identidad ACTUAL: el NOMBRE con el que ya te registraste antes en esta
  conversacion.
  - Si aun no te has registrado en esta sesion, pide el nombre en una linea y detente.
  - Si ya tienes NOMBRE: llama a inbox() y agents(), y muestrame lo que haya
    (mensajes nuevos y quien sigue conectado). Si hay mensajes, atiendelos.

Ritual recomendado antes de tocar trabajo compartido: register -> agents ->
get_state -> inbox (anunciate, mira quien mas esta y si se solapan, lee el estado
compartido, y vacia tu bandeja).

Tu identidad queda ligada a la sesion con register: los tools de stdio (send,
inbox, claim, release, whoami) usan tu identidad fijada, asi que ya NO se pasa
"NOMBRE" como argumento ni se puede suplantar a otra sesion.

En ambos casos, de aqui en adelante traduce mi lenguaje natural a las tools del bus:
- "quien soy" / "como me llamo"               -> whoami()
- "dile a X que ..." / "avisale a X ..."      -> send("X", "...")
- "avisa a todos ..." / "anuncia ..."         -> send("all", "...")
- "responde al mensaje N ..."                 -> send("X", "...", reply_to=N)
- "hay algo para mi" / "revisa el bus"        -> inbox()
- "echa un vistazo sin marcar leido"          -> inbox(peek=True)
- "quien leyo el mensaje N"                    -> message_status(N)
- "guarda ESTO como CLAVE"                    -> set_state("CLAVE", "...")
- "guarda solo si sigue en version V"         -> set_state("CLAVE", "...", expected_version=V)
- "agrega ESTO a CLAVE"                       -> set_state("CLAVE", "...", mode="append")
- "que hay en CLAVE" / "lee CLAVE"            -> get_state("CLAVE")
- "que claves hay" / "lista el estado"        -> list_state()
- "estoy editando ARCHIVO"                    -> claim("ARCHIVO")
- "ya termine con ARCHIVO"                     -> release("ARCHIVO")
- "quien edita que" / "lista reclamos"        -> list_claims()
- "quien esta conectado" / "lista sesiones"   -> agents()
CBUS_EOF_6
cat > "$DEST/setup.sh" <<'CBUS_EOF_7'
#!/usr/bin/env bash
# claude-bus local setup: prepares a Python that has the mcp package and
# registers the MCP server at user scope so every Claude Code session sees it.
# Run from anywhere:  bash setup.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUS_DB="${BUS_DB:-$HOME/.claude-bus/bus.db}"

echo "claude-bus dir : $DIR"
echo "shared db      : $BUS_DB"

# 1. pick a Python that has the mcp package. Prefer an isolated venv; fall back
#    to the current python3 (e.g. pyenv builds without the venv module) and
#    install mcp into it.
if [ -z "${BUS_NO_VENV:-}" ] && python3 -m venv "$DIR/.venv" >/dev/null 2>&1; then
  PYBIN="$DIR/.venv/bin/python"
else
  rm -rf "$DIR/.venv"
  PYBIN="$(python3 -c 'import sys; print(sys.executable)')"
  echo "venv not available; using current Python: $PYBIN"
fi

"$PYBIN" -m ensurepip --upgrade >/dev/null 2>&1 || true
"$PYBIN" -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true
if ! "$PYBIN" -m pip install --quiet mcp >/dev/null 2>&1; then
  "$PYBIN" -m pip install --quiet --break-system-packages mcp >/dev/null 2>&1 || true
fi
"$PYBIN" -c "import mcp" 2>/dev/null || { echo "ERROR: could not install the 'mcp' package for $PYBIN"; exit 1; }

# 2. shared db directory
mkdir -p "$(dirname "$BUS_DB")"

# 3. sanity check: the server imports cleanly
BUS_DB="$BUS_DB" "$PYBIN" -c "import importlib.util as u; s=u.spec_from_file_location('b','$DIR/bus_server.py'); m=u.module_from_spec(s); s.loader.exec_module(m); print('server imports OK')"

# 4. register the MCP server (user scope) if the claude CLI is on PATH
if command -v claude >/dev/null 2>&1; then
  claude mcp remove -s user bus >/dev/null 2>&1 || true
  # name first, then -e (variadic) right before -- so it stops at the command
  claude mcp add -s user bus -e BUS_DB="$BUS_DB" -- "$PYBIN" "$DIR/bus_server.py"
  echo
  echo "Registered 'bus' (user scope). Check with:  claude mcp list"
else
  echo
  echo "claude CLI not found on PATH. Register manually with:"
  echo "  claude mcp add -s user bus -e BUS_DB=\"$BUS_DB\" -- \"$PYBIN\" \"$DIR/bus_server.py\""
fi

# 5. install the /bus slash command (personal scope = all your projects)
mkdir -p "$HOME/.claude/commands"
cp "$DIR/commands/bus.md" "$HOME/.claude/commands/bus.md"
echo "Installed /bus command -> ~/.claude/commands/bus.md"

echo
echo "Next: open two terminals, run 'claude' in each, then just type:"
echo "  Terminal 1 ->  /bus backend"
echo "  Terminal 2 ->  /bus frontend"
echo "From then on talk normally, e.g. 'avisale al frontend que el login ya esta'."
CBUS_EOF_7
echo
echo "Files written. Running setup..."
bash "$DEST/setup.sh"
