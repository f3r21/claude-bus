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
