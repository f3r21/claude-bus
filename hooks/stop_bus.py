#!/usr/bin/env python3
"""
Stop hook for claude-bus. Makes a session REACT to incoming messages: when it is
about to stop, if there are unread messages addressed to it, the hook blocks the
stop and feeds them back, so the session keeps working instead of going idle.

Identity resolution (so the same script works as a local hook and as a plugin
hook): the session name is taken from the first CLI argument, else from $BUS_NAME.
If neither is set the hook is a silent no-op -- safe to enable globally, since a
session that never joined the bus has no name and nothing to pick up.

Loop safety: messages are marked read here, so a second Stop finds nothing and
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
    rows = conn.execute(
        "SELECT id, sender, content FROM messages "
        "WHERE read = 0 AND (recipient = ? OR recipient = 'all') AND sender != ? "
        "ORDER BY id",
        (name, name),
    ).fetchall()

    if not rows:
        conn.close()
        return 0

    ids = [r["id"] for r in rows]
    placeholders = ",".join("?" * len(ids))
    conn.execute(f"UPDATE messages SET read = 1 WHERE id IN ({placeholders})", ids)
    conn.execute(
        "INSERT INTO agents(name, role, last_seen) VALUES(?,?,?) "
        "ON CONFLICT(name) DO UPDATE SET last_seen=excluded.last_seen",
        (name, "", time.time()),
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
