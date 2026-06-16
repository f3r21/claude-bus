"""T0.2 -- CAS, append, and discovery on shared state."""

import pytest

from claude_bus import core

pytestmark = pytest.mark.unit


def test_new_key_starts_at_version_1():
    assert core.set_state("k", "v1", by="alice") == 1


def test_get_state_returns_enriched_shape():
    core.set_state("k", "v1", by="alice")
    [row] = core.get_state("k")
    assert row["key"] == "k"
    assert row["value"] == "v1"
    assert row["updated_by"] == "alice"
    assert row["version"] == 1
    assert isinstance(row["updated_at"], float)


def test_cas_success_increments_version():
    core.set_state("k", "v1")
    assert core.set_state("k", "v2", expected_version=1) == 2


def test_two_writers_same_expected_version_second_is_rejected():
    core.set_state("k", "base")  # version 1
    assert core.set_state("k", "A", expected_version=1) == 2  # first wins
    with pytest.raises(ValueError) as exc:
        core.set_state("k", "B", expected_version=1)  # stale
    assert "current 2" in str(exc.value)
    [row] = core.get_state("k")
    assert row["value"] == "A"
    assert row["version"] == 2


def test_cas_create_with_expected_version_zero():
    assert core.set_state("k", "v", expected_version=0) == 1


def test_cas_create_with_wrong_expected_version_rejected():
    with pytest.raises(ValueError):
        core.set_state("k", "v", expected_version=1)


def test_append_accumulates_without_clobber():
    core.set_state("log", "line1", by="a")
    assert core.set_state("log", "line2", by="b", mode="append") == 2
    [row] = core.get_state("log")
    assert row["value"] == "line1\nline2"
    assert row["version"] == 2


def test_append_on_missing_key_creates_it():
    assert core.set_state("log", "first", mode="append") == 1
    [row] = core.get_state("log")
    assert row["value"] == "first"


def test_list_state_reveals_keys_without_values():
    core.set_state("a", "x", by="alice")
    core.set_state("b", "y", by="bob")
    listed = core.list_state()
    assert {r["key"] for r in listed} == {"a", "b"}
    assert all("value" not in r for r in listed)
    assert all("version" in r and "updated_by" in r for r in listed)


def test_unknown_mode_rejected():
    with pytest.raises(ValueError):
        core.set_state("k", "v", mode="bogus")
