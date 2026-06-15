#!/usr/bin/env bash
# Self-contained local installer for claude-bus. Creates ~/claude-bus and runs setup.
# Usage:  bash install_claude_bus.sh   (or pass a target dir as $1)
set -euo pipefail
DEST="${1:-$HOME/claude-bus}"
mkdir -p "$DEST/src/claude_bus" "$DEST/hooks" "$DEST/commands"
echo "Scaffolding claude-bus into $DEST"
cat > "$DEST/src/claude_bus/__init__.py" <<'CBUS_EOF_0'
"""claude-bus: a shared message and state bus for multiple Claude Code sessions."""

__version__ = "0.1.0"
CBUS_EOF_0
cat > "$DEST/src/claude_bus/core.py" <<'CBUS_EOF_1'
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
CBUS_EOF_1
cat > "$DEST/src/claude_bus/server.py" <<'CBUS_EOF_2'
"""FastMCP server exposing the bus over stdio (one process per session)."""

from mcp.server.fastmcp import FastMCP

from . import core

core.init()

mcp = FastMCP("claude-bus")


@mcp.tool()
def register(name: str, role: str = "") -> str:
    """Announce this session on the bus (also acts as a heartbeat).

    name: stable identifier for this session, e.g. 'backend' or 'frontend'.
    role: free-text description of what this session is responsible for.
    """
    return core.register(name, role)


@mcp.tool()
def agents(active_within: float = 180.0) -> list:
    """List sessions seen within the last `active_within` seconds."""
    return core.agents(active_within)


@mcp.tool()
def send(sender: str, to: str, content: str) -> str:
    """Send a message to another session. `to` is a name, or 'all' to broadcast."""
    return core.send(sender, to, content)


@mcp.tool()
def inbox(name: str, mark_read: bool = True) -> list:
    """Pull unread messages for `name` (direct messages + broadcasts)."""
    return core.inbox(name, mark_read)


@mcp.tool()
def set_state(key: str, value: str, by: str = "") -> str:
    """Write a shared key on the blackboard every session can read."""
    return core.set_state(key, value, by)


@mcp.tool()
def get_state(key: str = "") -> list:
    """Read one shared key, or every key if `key` is empty."""
    return core.get_state(key)


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
CBUS_EOF_4
cat > "$DEST/hooks/inject_state.py" <<'CBUS_EOF_5'
#!/usr/bin/env python3
"""
UserPromptSubmit hook for claude-bus. Injects current bus state as context every
time you send a prompt, so the session always knows who else is connected and
whether messages are waiting.

Identity: first CLI argument, else $BUS_NAME. No identity -> silent no-op.
For UserPromptSubmit, stdout (exit 0) is added to the model's context.
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
    pending = conn.execute(
        "SELECT COUNT(*) AS n FROM messages "
        "WHERE read = 0 AND (recipient = ? OR recipient = 'all') AND sender != ?",
        (name, name),
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
  1. register(NOMBRE, ROL)   -- anunciarte en el bus
  2. agents()                -- ver quien mas esta conectado
  3. inbox(NOMBRE)           -- recoger mensajes que te esperan
  Confirma en UNA linea quien eres y quien mas esta en el bus.

CASO B -- el argumento esta vacio ("revisa el bus"):
  Usa tu identidad ACTUAL: el NOMBRE con el que ya te registraste antes en esta
  conversacion.
  - Si aun no te has registrado en esta sesion, pide el nombre en una linea y detente.
  - Si ya tienes NOMBRE: llama a inbox(NOMBRE) y agents(), y muestrame lo que haya
    (mensajes nuevos y quien sigue conectado). Si hay mensajes, atiendelos.

En ambos casos, de aqui en adelante traduce mi lenguaje natural a las tools del bus
(NOMBRE = tu nombre):
- "dile a X que ..." / "avisale a X ..."      -> send(NOMBRE, "X", "...")
- "avisa a todos ..." / "anuncia ..."         -> send(NOMBRE, "all", "...")
- "hay algo para mi" / "revisa el bus"        -> inbox(NOMBRE)
- "guarda ESTO como CLAVE" / "comparte ..."   -> set_state("CLAVE", "...", NOMBRE)
- "que hay en CLAVE" / "lee CLAVE"            -> get_state("CLAVE")
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
