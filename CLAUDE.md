# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

claude-bus is a shared message/state bus that lets multiple Claude Code sessions
coordinate. It is a small MCP server backed by a **single SQLite file**, plus a
`/bus` slash command and reactive hooks. The same codebase ships four ways: local
installer, Claude Code plugin, PyPI package, and a Docker HTTP service.

The core constraint that shapes everything: Claude Code is turn-based with **no
native push**. A session only "sees" the bus when a tool returns or a hook injects
text. So coordination = a shared store (SQLite) + a poll convention or hook that
makes each session check it.

## Architecture

Single source of truth is `src/claude_bus/core.py` — all SQLite access and the bus
operations (`register`, `whoami`, `agents`, `send`, `inbox`, `message_status`,
`set_state`, `get_state`, `list_state`, `claim`, `release`, `list_claims`) over five
tables: `agents`, `messages`, `deliveries`, `state`, `claims`. `core` stays
**stateless** — every operation takes identity (`name`/`sender`) explicitly so it is
unit-testable in isolation; the binding of identity to a session lives in the server
layer. Everything else wraps it:

- `server.py` — stdio transport (FastMCP). **One server process per session**;
  sessions share state only through the DB file (WAL handles concurrent writes).
- `http_server.py` — streamable-http transport. **One process serves many clients**.
  Defines its **own** `mcp` with **explicit-identity** tools (`send(sender, …)`,
  `inbox(name, …)`) over the same `core`, because a module-global identity can't tell
  HTTP connections apart. Documented limitation: HTTP does not get stdio's anti-spoofing.
- `bus_server.py` — thin shim that puts `src/` on `sys.path` and runs `server.main`,
  so installers run the same packaged implementation rather than a copy.

**Identity binding (T0.3):** `server.py` holds a module-global `_identity` set by the
first `register`; `send`/`inbox`/`claim`/`release`/`whoami` derive the actor from it
and raise `"register first"` if unset. Since each stdio session is its own process,
this makes spoofing impossible. `core` itself stays identity-as-argument.

DB path comes from `$BUS_DB` (default `~/.claude-bus/bus.db`). `agents()` only returns
peers seen within `active_within` seconds (default 180). **Delivery is a per-agent
cursor** (`agents.last_read_id`), not a per-row flag: `inbox` returns messages with
`id > cursor` and `recipient = name OR 'all'` and `sender != name`; `consume` advances
the cursor to `MAX(messages.id)` and writes `deliveries` receipts, `peek` doesn't. A
fresh agent starts at cursor 0, so it still receives broadcasts sent before it joined
(a deliberately preserved invariant). `state` is versioned for compare-and-set;
`claims` are advisory TTL soft-locks.

### Reactivity (hooks)

Hooks are what provide reactivity in every mode. Both resolve session identity the
same way: **first CLI arg, else `$BUS_NAME`, else silent no-op** (safe to enable globally).

- `hooks/stop_bus.py` — `Stop` hook. If messages exist past the cursor, blocks the
  stop and feeds them back. Loop safety: it advances the cursor to `MAX(id)` and writes
  receipts *before* blocking (a second Stop finds nothing) and honors `stop_hook_active`.
- `hooks/inject_state.py` — `UserPromptSubmit` hook. Prints peer list + unread count
  (messages past the cursor) into context on every prompt.

> **Important duplication to keep in sync:** the hooks talk to SQLite **directly**
> (raw `sqlite3` queries), not through `core.py`. Any change to the schema or the
> cursor-based visibility query (`id > last_read_id`, `recipient`/`all`,
> `sender != name`) must be mirrored in `core.py`, `stop_bus.py`, and `inject_state.py`.

### Distribution (one repo, four targets)

The repo is simultaneously a Python package, a plugin, and a single-plugin marketplace.

- `.claude-plugin/plugin.json` + `marketplace.json` — plugin & marketplace manifests.
- `.mcp.json` — plugin's MCP server; runs `uvx --from "${CLAUDE_PLUGIN_ROOT}" claude-bus`.
- `pyproject.toml` — hatchling build; console scripts `claude-bus` (stdio) and
  `claude-bus-http` (HTTP); only runtime dep is `mcp`.
- `Dockerfile` / `docker-compose.yml` — HTTP deploy (`BUS_HOST`/`BUS_PORT`/`BUS_DB`).
- `install_claude_bus.sh` — **self-contained installer that re-emits the entire
  source via heredocs**. It contains a second copy of `core.py`, the hooks, etc.
  Editing real source under `src/` does **not** update this script — regenerate it
  if a release needs to stay self-contained.

## Commands

```bash
# Local dev install: registers the MCP server at user scope + installs /bus
bash setup.sh                      # uses src/ via bus_server.py
bash install_claude_bus.sh         # self-contained: scaffolds ~/claude-bus then runs setup

# Build / publish the package
python -m build                    # wheel + sdist into dist/
twine upload dist/*

# Run a transport directly (after `pip install .`)
claude-bus                         # stdio (one per session)
claude-bus-http                    # HTTP on :8765, honors BUS_HOST/BUS_PORT/BUS_DB

# HTTP deploy
docker compose up -d               # serves :8765, data in the bus-data volume

# Register a client against a server
claude mcp add -s user bus -- uvx claude-bus                      # local via uvx
claude mcp add --transport http bus http://HOST:8765/mcp         # remote HTTP

# Inspect the bus state (note: no messages.read flag; deliveries holds receipts)
sqlite3 ~/.claude-bus/bus.db 'SELECT * FROM messages; SELECT * FROM agents; SELECT * FROM claims;'

# Tests / lint / format (install dev extras first: pip install -e ".[dev]")
pytest -q                          # 42 tests; markers: unit, integration
ruff check src tests               # + black --check / isort --check-only
```

Tests live in `tests/` and isolate via a `$BUS_DB` temp file per test (`conftest.py`
sets it through `monkeypatch` before each test and resets `server._identity`).
`core.db_path()` reads `$BUS_DB` per call, so this isolates cleanly.

## Conventions & gotchas

- All operations open a short-lived connection (`core._connect`) with WAL +
  `busy_timeout`; there is no long-lived connection or pooling — keep it that way so
  independent processes stay safe.
- The `/bus` command (`commands/bus.md`) is written in **Spanish** and maps natural
  language to the tools. Match that style if you extend it.
- `examples/settings.json` hard-codes the identity `backend` as a hook argument;
  it's a template, so the name is meant to be edited per session.
