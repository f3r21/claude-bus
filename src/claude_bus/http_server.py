"""
Run the bus over HTTP (streamable-http) instead of stdio. Use this for an
always-on bus that several machines connect to by URL.

  BUS_HOST  bind address (default 0.0.0.0)
  BUS_PORT  port (default 8765)
  BUS_DB    sqlite path (default ~/.claude-bus/bus.db)

Clients connect with:
  claude mcp add --transport http bus http://HOST:8765/mcp
"""

import os

from . import core
from .server import mcp


def main() -> None:
    core.init()
    mcp.settings.host = os.environ.get("BUS_HOST", "0.0.0.0")
    mcp.settings.port = int(os.environ.get("BUS_PORT", "8765"))
    mcp.run(transport="streamable-http")


if __name__ == "__main__":
    main()
