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
