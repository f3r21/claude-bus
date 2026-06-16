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
