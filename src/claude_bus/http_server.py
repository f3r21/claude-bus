"""
Run the bus over HTTP (streamable-http) instead of stdio. Use this for an
always-on bus that several machines connect to by URL.

  BUS_HOST  bind address (default 0.0.0.0)
  BUS_PORT  port (default 8765)
  BUS_DB    sqlite path (default ~/.claude-bus/bus.db)

Clients connect with:
  claude mcp add --transport http bus http://HOST:8765/mcp

Identity note: the stdio transport binds one identity per server process
(``server.py``). HTTP is a single process serving many clients, so that
process-local binding cannot tell connections apart. This transport therefore
takes identity explicitly on every call (``send(sender, ...)``,
``inbox(name, ...)``) over the same ``core``. It is the right choice for a
shared multi-client bus, but it does NOT provide the stdio anti-spoofing
guarantee -- callers can name any sender. Use stdio when that guarantee matters.
"""

import os
from typing import Optional

from mcp.server.fastmcp import FastMCP

from . import core

mcp = FastMCP("claude-bus")


@mcp.tool()
def register(name: str, role: str = "", owns: Optional[list] = None) -> str:
    """Announce a session and optionally declare the file globs it owns."""
    return core.register(name, role, owns)


@mcp.tool()
def whoami() -> str:
    """HTTP uses explicit identity per call; there is no per-connection binding."""
    return "http transport: pass identity explicitly (e.g. send(sender, ...))"


@mcp.tool()
def agents(active_within: float = 180.0) -> list:
    """List sessions seen within the last `active_within` seconds, with overlaps."""
    return core.agents(active_within)


@mcp.tool()
def send(sender: str, to: str, content: str, reply_to: Optional[int] = None) -> str:
    """Send a message from `sender`. `to` is a peer name or 'all' to broadcast."""
    msg_id = core.send(sender, to, content, reply_to)
    return f"sent to '{to}' (id {msg_id})"


@mcp.tool()
def inbox(name: str, consume: bool = True, peek: bool = False) -> dict:
    """Pull messages newer than `name`'s read cursor. Returns {messages, pending_count}."""
    return core.inbox(name, consume=consume, peek=peek)


@mcp.tool()
def message_status(message_id: int) -> dict:
    """Show which recipients have read a message and when."""
    return core.message_status(message_id)


@mcp.tool()
def set_state(
    key: str,
    value: str,
    by: str = "",
    expected_version: Optional[int] = None,
    mode: str = "overwrite",
) -> str:
    """Write a shared key. Pass expected_version for compare-and-set; mode='append' to accumulate."""
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
def claim(path: str, owner: str, ttl: float = 1800.0) -> str:
    """Place an advisory soft-lock on `path` for `owner`. Advisory only."""
    return core.claim(path, owner, ttl)


@mcp.tool()
def release(path: str, owner: str) -> str:
    """Release a claim held by `owner`."""
    return core.release(path, owner)


@mcp.tool()
def list_claims() -> list:
    """List active (non-expired) file claims and their remaining TTL."""
    return core.list_claims()


def main() -> None:
    core.init()
    mcp.settings.host = os.environ.get("BUS_HOST", "0.0.0.0")
    mcp.settings.port = int(os.environ.get("BUS_PORT", "8765"))
    mcp.run(transport="streamable-http")


if __name__ == "__main__":
    main()
