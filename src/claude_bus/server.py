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
