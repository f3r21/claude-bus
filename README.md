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

Tools exposed: `register`, `whoami`, `agents`, `send`, `inbox`, `message_status`,
`set_state`, `get_state`, `list_state`, `claim`, `release`, `list_claims`.

### What v0.2 changed (breaking)

- **Per-recipient delivery.** Each session has a read cursor; a broadcast reaches
  every recipient independently (v0.1 lost it after the first reader). `inbox`
  returns `{messages, pending_count}`; `inbox(peek=True)` reads without consuming so
  history can be re-read; late joiners still receive earlier broadcasts.
- **Compare-and-set state.** `set_state(key, value, expected_version=…)` rejects a
  stale write (the error reports the current version); `mode="append"` accumulates;
  `get_state` now returns `{value, updated_by, updated_at, version}` and `list_state`
  lists keys without values. `message_status(id)` shows who has read a message.
- **Session-bound identity (stdio).** The sender is the session's own registered
  identity, not a free-text argument, so a session can't post as another. Call
  `register` first; `whoami` reports your bound name. The HTTP transport serves many
  clients from one process, so it takes identity explicitly and does **not** provide
  this anti-spoofing guarantee.
- **Advisory file claims.** `claim(path, ttl=1800)` / `release(path)` /
  `list_claims()` announce "I'm editing this"; `register(owns=[globs])` makes
  `agents()` flag sessions whose files overlap. Claims are advisory — they never lock
  the filesystem.

Existing `~/.claude-bus/bus.db` files are migrated automatically (`PRAGMA
user_version`): shared `state` is preserved; pending messages are reset (the read
model changed incompatibly).

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

Recommended startup ritual before touching shared work: **`register` → `agents` →
`get_state` → `inbox`** — announce yourself, see who else is here and whether you
overlap, read the shared blackboard, then drain your inbox.

After joining, natural language maps to the tools (the stdio tools use your bound
identity, so there is no `sender`/`name` argument to pass or forge):

| You say | Tool |
|---|---|
| "who am I on the bus?" | `whoami()` |
| "tell frontend the login is ready" | `send("frontend", ...)` |
| "broadcast to everyone ..." | `send("all", ...)` |
| "anything for me? / check the bus" | `inbox()` |
| "let me peek without marking read" | `inbox(peek=True)` |
| "who has read message 7?" | `message_status(7)` |
| "save X as login_schema (only if still v3)" | `set_state("login_schema", X, expected_version=3)` |
| "append this fix to the fixes log" | `set_state("fixes", "...", mode="append")` |
| "what's in login_schema?" | `get_state("login_schema")` |
| "what keys exist?" | `list_state()` |
| "I'm editing Cap_4.tex" | `claim("Cap_4.tex")` |
| "I'm done with Cap_4.tex" | `release("Cap_4.tex")` |
| "who's editing what?" | `list_claims()` |
| "who's connected?" | `agents()` |

### Reactive mode (hooks)

Polling works, but to make a session pick up messages **on its own** when it
finishes a turn, enable the `Stop` hook. With the plugin it ships in
`hooks/hooks.json`; it acts only when `BUS_NAME` is set, so set the same name you
join with:

```bash
export BUS_NAME=backend && claude        # then /bus backend
```

The hook advances the session's read cursor (and records receipts) before blocking,
so a second Stop finds nothing new and there is no infinite loop (it also honors
`stop_hook_active`).

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
