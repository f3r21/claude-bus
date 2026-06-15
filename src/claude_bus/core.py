"""
Storage and operations for claude-bus.

All bus state lives in one SQLite file (WAL mode). Independent server processes
-- one per Claude Code session for the stdio transport -- coordinate through
that file. The HTTP transport uses a single process but the same schema, so a
local stdio bus and a remote HTTP bus are interchangeable backends.

The DB path is taken from $BUS_DB, defaulting to ~/.claude-bus/bus.db.
"""

import os
import sqlite3
import time
from pathlib import Path


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


def init() -> None:
    with _connect() as c:
        c.execute(
            "CREATE TABLE IF NOT EXISTS messages("
            "id INTEGER PRIMARY KEY AUTOINCREMENT,"
            "ts REAL, sender TEXT, recipient TEXT, content TEXT,"
            "read INTEGER DEFAULT 0)"
        )
        c.execute(
            "CREATE TABLE IF NOT EXISTS state("
            "key TEXT PRIMARY KEY, value TEXT, updated_by TEXT, ts REAL)"
        )
        c.execute(
            "CREATE TABLE IF NOT EXISTS agents("
            "name TEXT PRIMARY KEY, role TEXT, last_seen REAL)"
        )


def _heartbeat(c: sqlite3.Connection, name: str, role: str = "") -> None:
    c.execute(
        "INSERT INTO agents(name, role, last_seen) VALUES(?,?,?) "
        "ON CONFLICT(name) DO UPDATE SET "
        "role=CASE WHEN excluded.role != '' THEN excluded.role ELSE agents.role END, "
        "last_seen=excluded.last_seen",
        (name, role, time.time()),
    )


def register(name: str, role: str = "") -> str:
    with _connect() as c:
        _heartbeat(c, name, role)
    return f"registered '{name}'" + (f" ({role})" if role else "")


def agents(active_within: float = 180.0) -> list:
    cutoff = time.time() - active_within
    with _connect() as c:
        rows = c.execute(
            "SELECT name, role, last_seen FROM agents "
            "WHERE last_seen >= ? ORDER BY last_seen DESC",
            (cutoff,),
        ).fetchall()
    now = time.time()
    return [
        {"name": r["name"], "role": r["role"], "seconds_ago": round(now - r["last_seen"], 1)}
        for r in rows
    ]


def send(sender: str, to: str, content: str) -> str:
    with _connect() as c:
        c.execute(
            "INSERT INTO messages(ts, sender, recipient, content) VALUES(?,?,?,?)",
            (time.time(), sender, to, content),
        )
        _heartbeat(c, sender)
    return f"sent to '{to}'"


def inbox(name: str, mark_read: bool = True) -> list:
    with _connect() as c:
        rows = c.execute(
            "SELECT id, ts, sender, recipient, content FROM messages "
            "WHERE read = 0 AND (recipient = ? OR recipient = 'all') AND sender != ? "
            "ORDER BY id",
            (name, name),
        ).fetchall()
        if mark_read and rows:
            ids = [r["id"] for r in rows]
            placeholders = ",".join("?" * len(ids))
            c.execute(f"UPDATE messages SET read = 1 WHERE id IN ({placeholders})", ids)
        _heartbeat(c, name)
    return [
        {"from": r["sender"], "to": r["recipient"], "content": r["content"], "id": r["id"]}
        for r in rows
    ]


def set_state(key: str, value: str, by: str = "") -> str:
    with _connect() as c:
        c.execute(
            "INSERT INTO state(key, value, updated_by, ts) VALUES(?,?,?,?) "
            "ON CONFLICT(key) DO UPDATE SET "
            "value=excluded.value, updated_by=excluded.updated_by, ts=excluded.ts",
            (key, value, by, time.time()),
        )
    return f"state['{key}'] set"


def get_state(key: str = "") -> list:
    with _connect() as c:
        if key:
            rows = c.execute("SELECT * FROM state WHERE key = ?", (key,)).fetchall()
        else:
            rows = c.execute("SELECT * FROM state ORDER BY key").fetchall()
    return [
        {"key": r["key"], "value": r["value"], "updated_by": r["updated_by"]}
        for r in rows
    ]
