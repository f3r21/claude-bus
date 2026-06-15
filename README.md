# claude-bus

A shared message and state bus that lets **two or more Claude Code sessions
communicate, exchange state, and stay coordinated**. It is a small MCP server
backed by a single SQLite file, plus an optional slash command and hooks.

## The idea (and the one limit to understand first)

Claude Code works in **turns**: the model only "sees" outside data when a tool
returns a result or a hook injects text. There is **no native push** that wakes a
session mid-turn. So "staying connected" is built from two pieces:

1. A **shared store** (the bus) every session reads and writes — for exchanging
   state and messages.
2. A **poll convention or a hook** that makes each session check the bus — so they
   *react* to what the other left.

This project ships both.

## Architecture

```
  Session A (terminal 1)        Session B (terminal 2)
  claude  ->  bus (MCP)         claude  ->  bus (MCP)        one server per session
                  \                   /
                   v                 v
              ~/.claude-bus/bus.db   (SQLite WAL = the bus, the real shared state)
```

For the local stdio transport each session launches its own server process; they
share state through the SQLite file (WAL handles concurrent writes). For the HTTP
transport a single process serves every client. Both use the same schema, so they
are interchangeable backends.

Tools exposed: `register`, `agents`, `send`, `inbox`, `set_state`, `get_state`.

---

## Install — pick one

### 1. Quick local (one command)

No Python packaging, no plugin. Good for one machine.

```bash
bash install_claude_bus.sh          # creates ~/claude-bus, registers the MCP server
```

It registers the `bus` server at user scope and installs the `/bus` command. Then
open two terminals, run `claude` in each, and type `/bus backend` / `/bus frontend`.

### 2. Claude Code plugin (recommended for sharing)

This whole repo is also a plugin **and** a single-plugin marketplace. Anyone with
Claude Code installs the MCP server, the `/bus` command, and the reactive hook in
one step. Requires [`uv`](https://docs.astral.sh/uv/) on PATH (`brew install uv`),
which runs the bundled package with no manual venv.

```
/plugin marketplace add f3r21/claude-bus
/plugin install claude-bus@claude-bus
```

The plugin's `.mcp.json` runs the server via `uvx --from "${CLAUDE_PLUGIN_ROOT}"
claude-bus`, so it works straight from the installed plugin directory.

### 3. PyPI + uvx (clean server install)

Publish the package, then any session points at it with zero venv management:

```bash
python -m build && twine upload dist/*        # one-time publish
# then, on any machine:
claude mcp add -s user bus -- uvx claude-bus
```

`uvx` resolves and caches dependencies like `npx` for Python — this is the cleanest
fix if you hit venv issues (e.g. a pyenv build without the `venv` module).

### 4. HTTP server + Docker (multi-machine / always-on)

Run one shared bus other machines connect to by URL.

```bash
docker compose up -d                          # serves on :8765, data in a volume
# on each client machine:
claude mcp add --transport http bus http://YOUR_HOST:8765/mcp
```

Without Docker: `pip install . && claude-bus-http` (honors `BUS_HOST`, `BUS_PORT`,
`BUS_DB`).

---

## Usage

Give each session an identity once, then talk normally:

- `/bus backend` — join as `backend` (registers, lists peers, reads inbox).
- `/bus` (no argument) — "check the bus": read your inbox and see who is connected.

After joining, natural language maps to the tools:

| You say | Tool |
|---|---|
| "tell frontend the login is ready" | `send("backend","frontend",...)` |
| "broadcast to everyone ..." | `send("backend","all",...)` |
| "anything for me? / check the bus" | `inbox("backend")` |
| "save X as login_schema" | `set_state("login_schema",...)` |
| "what's in login_schema?" | `get_state("login_schema")` |
| "who's connected?" | `agents()` |

### Reactive mode (hooks)

Polling works, but to make a session pick up messages **on its own** when it
finishes a turn, enable the `Stop` hook. With the plugin it ships in
`hooks/hooks.json`; it acts only when `BUS_NAME` is set, so set the same name you
join with:

```bash
export BUS_NAME=backend && claude        # then /bus backend
```

The hook marks messages read before blocking, so there is no infinite loop (and it
honors `stop_hook_active`).

---

## Repository layout

```
claude-bus/
  .claude-plugin/
    plugin.json            plugin manifest
    marketplace.json       single-plugin marketplace (source ".")
  .mcp.json                plugin MCP server (uvx, ${CLAUDE_PLUGIN_ROOT})
  commands/bus.md          the /bus slash command
  hooks/
    hooks.json             plugin Stop hook
    stop_bus.py            reactive: re-inject pending messages
    inject_state.py        optional: inject bus state on each prompt
  src/claude_bus/
    core.py                SQLite + tool logic (shared by all transports)
    server.py              stdio entry point  -> claude-bus
    http_server.py         http entry point   -> claude-bus-http
  bus_server.py            thin shim used by the local installer
  pyproject.toml           PyPI packaging + console scripts
  Dockerfile               + docker-compose.yml for the HTTP deploy
  setup.sh                 local register/install helper
  install_claude_bus.sh    self-contained local installer
```

## Notes and limits

- Same machine, a few sessions: stdio + SQLite is plenty (and durable).
- Different machines: use the HTTP transport. Push still doesn't exist; hooks are
  what provide reactivity in every mode.
- For one session spawning parallel subtasks (parent -> child, not peers), use
  Claude Code subagents instead — no bus needed.

## License

MIT — see [LICENSE](LICENSE).
