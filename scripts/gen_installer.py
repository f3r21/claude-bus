#!/usr/bin/env python3
"""Regenerate install_claude_bus.sh from the real source tree.

The self-contained installer embeds a verbatim copy of the stdio source (so it
can scaffold a working bus with no checkout). That copy must match src/, hooks/,
commands/, and setup.sh exactly. Rather than hand-edit the embedded heredocs,
run this after changing any embedded file:

    python scripts/gen_installer.py

It reads each source file and writes the heredoc blocks, so the embedded copy can
never drift from the real source.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# (source path relative to repo root, destination path in the generated installer)
EMBEDDED = [
    ("src/claude_bus/__init__.py", "$DEST/src/claude_bus/__init__.py"),
    ("src/claude_bus/core.py", "$DEST/src/claude_bus/core.py"),
    ("src/claude_bus/server.py", "$DEST/src/claude_bus/server.py"),
    ("bus_server.py", "$DEST/bus_server.py"),
    ("hooks/stop_bus.py", "$DEST/hooks/stop_bus.py"),
    ("hooks/inject_state.py", "$DEST/hooks/inject_state.py"),
    ("commands/bus.md", "$DEST/commands/bus.md"),
    ("setup.sh", "$DEST/setup.sh"),
]

HEADER = """#!/usr/bin/env bash
# Self-contained local installer for claude-bus. Creates ~/claude-bus and runs setup.
# Usage:  bash install_claude_bus.sh   (or pass a target dir as $1)
#
# GENERATED FILE -- do not hand-edit the heredocs below. They embed a verbatim copy
# of the stdio source tree. Re-run `python scripts/gen_installer.py` after changing
# any embedded file (src/, hooks/, commands/, setup.sh) so the copy stays in sync.
set -euo pipefail
DEST="${1:-$HOME/claude-bus}"
mkdir -p "$DEST/src/claude_bus" "$DEST/hooks" "$DEST/commands"
echo "Scaffolding claude-bus into $DEST"
"""

FOOTER = """echo
echo "Files written. Running setup..."
bash "$DEST/setup.sh"
"""


def main() -> None:
    parts = [HEADER]
    for idx, (src, dest) in enumerate(EMBEDDED):
        content = (ROOT / src).read_text()
        if not content.endswith("\n"):
            content += "\n"
        eof = f"CBUS_EOF_{idx}"
        if eof in content:
            raise ValueError(f"heredoc delimiter {eof} collides with content of {src}")
        parts.append(f"cat > \"{dest}\" <<'{eof}'\n{content}{eof}\n")
    parts.append(FOOTER)
    (ROOT / "install_claude_bus.sh").write_text("".join(parts))
    print("wrote install_claude_bus.sh")


if __name__ == "__main__":
    main()
