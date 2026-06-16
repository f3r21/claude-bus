"""Shared pytest fixtures: every test gets its own throwaway $BUS_DB."""

import os
import tempfile

# Point BUS_DB at a throwaway location BEFORE importing the package, so the
# import-time core.init() in server.py never touches the real ~/.claude-bus DB.
_TMP_ROOT = tempfile.mkdtemp(prefix="claude-bus-tests-")
os.environ["BUS_DB"] = os.path.join(_TMP_ROOT, "import.db")

import pytest  # noqa: E402

from claude_bus import core, server  # noqa: E402


@pytest.fixture(autouse=True)
def isolated_db(tmp_path, monkeypatch):
    """Give each test a fresh database and reset the server's bound identity."""
    db = tmp_path / "bus.db"
    monkeypatch.setenv("BUS_DB", str(db))
    core.init()
    server._identity = None
    yield db
    server._identity = None
