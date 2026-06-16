"""Migration -- a simulated v0.1 database upgrades to v2 idempotently."""

import sqlite3

import pytest

from claude_bus import core

pytestmark = pytest.mark.unit


def _make_v1_db(path: str) -> None:
    """Recreate the v0.1 schema (no user_version, messages.read flag, no version)."""
    conn = sqlite3.connect(path)
    conn.execute(
        "CREATE TABLE messages(id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, "
        "sender TEXT, recipient TEXT, content TEXT, read INTEGER DEFAULT 0)"
    )
    conn.execute(
        "CREATE TABLE state(key TEXT PRIMARY KEY, value TEXT, updated_by TEXT, ts REAL)"
    )
    conn.execute(
        "CREATE TABLE agents(name TEXT PRIMARY KEY, role TEXT, last_seen REAL)"
    )
    conn.execute(
        "INSERT INTO state(key, value, updated_by, ts) "
        "VALUES('schema', 'login', 'alice', 123.0)"
    )
    conn.execute(
        "INSERT INTO messages(ts, sender, recipient, content, read) "
        "VALUES(1.0, 'a', 'b', 'old', 0)"
    )
    conn.execute(
        "INSERT INTO agents(name, role, last_seen) VALUES('alice', 'dev', 1.0)"
    )
    conn.commit()
    conn.close()


def test_migration_preserves_state_and_upgrades(tmp_path, monkeypatch):
    db = tmp_path / "v1.db"
    _make_v1_db(str(db))
    monkeypatch.setenv("BUS_DB", str(db))

    core.init()

    [row] = core.get_state("schema")
    assert row["value"] == "login"
    assert row["updated_by"] == "alice"
    assert row["version"] == 1

    conn = sqlite3.connect(str(db))
    uv = conn.execute("PRAGMA user_version").fetchone()[0]
    conn.close()
    assert uv == 2

    # New v2 tables/columns are usable.
    core.claim("x", "alice")
    assert core.list_claims()[0]["path"] == "x"


def test_migration_is_idempotent(tmp_path, monkeypatch):
    db = tmp_path / "v1.db"
    _make_v1_db(str(db))
    monkeypatch.setenv("BUS_DB", str(db))

    core.init()
    core.set_state("k", "v")
    core.init()  # second run must not wipe data

    assert core.get_state("k")[0]["value"] == "v"
    assert core.get_state("schema")[0]["value"] == "login"


def test_messages_reset_on_migration(tmp_path, monkeypatch):
    db = tmp_path / "v1.db"
    _make_v1_db(str(db))
    monkeypatch.setenv("BUS_DB", str(db))

    core.init()
    core.register("b")
    # The old buggy message was dropped during migration.
    assert core.inbox("b")["messages"] == []
