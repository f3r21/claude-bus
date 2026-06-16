"""T0.1 -- per-recipient delivery, cursor peek/consume, threading, receipts."""

import pytest

from claude_bus import core

pytestmark = pytest.mark.unit


def test_broadcast_received_independently_by_each_recipient():
    for n in ("A", "B", "C"):
        core.register(n)
    core.send("A", "all", "hello everyone")
    b = core.inbox("B")
    c = core.inbox("C")
    assert [m["content"] for m in b["messages"]] == ["hello everyone"]
    assert [m["content"] for m in c["messages"]] == ["hello everyone"]


def test_one_reader_does_not_hide_broadcast_from_others():
    for n in ("A", "B", "C"):
        core.register(n)
    core.send("A", "all", "msg")
    core.inbox("B", consume=True)
    c = core.inbox("C")
    assert len(c["messages"]) == 1


def test_sender_excluded_from_own_broadcast():
    core.register("A")
    core.send("A", "all", "mine")
    assert core.inbox("A")["messages"] == []


def test_late_joiner_receives_earlier_broadcast():
    core.register("A")
    core.send("A", "all", "before D joined")
    core.register("D")  # joins after the send
    d = core.inbox("D")
    assert [m["content"] for m in d["messages"]] == ["before D joined"]


def test_peek_does_not_consume():
    core.register("A")
    core.register("B")
    core.send("A", "B", "hi")
    first = core.inbox("B", peek=True)
    second = core.inbox("B", peek=True)
    assert len(first["messages"]) == 1
    assert len(second["messages"]) == 1
    assert first["pending_count"] == 1


def test_consume_advances_cursor_and_does_not_redeliver():
    core.register("A")
    core.register("B")
    core.send("A", "B", "hi")
    first = core.inbox("B", consume=True)
    second = core.inbox("B", consume=True)
    assert len(first["messages"]) == 1
    assert first["pending_count"] == 0
    assert second["messages"] == []


def test_pending_count_reflects_unread_after_call():
    core.register("A")
    core.register("B")
    core.send("A", "B", "1")
    core.send("A", "B", "2")
    assert core.inbox("B", peek=True)["pending_count"] == 2
    assert core.inbox("B", consume=True)["pending_count"] == 0


def test_reply_to_is_exposed():
    core.register("A")
    core.register("B")
    first = core.send("A", "B", "question")
    core.send("B", "A", "answer", reply_to=first)
    a = core.inbox("A")
    assert a["messages"][0]["reply_to"] == first


def test_directed_message_not_seen_by_others():
    for n in ("A", "B", "C"):
        core.register(n)
    core.send("A", "B", "private")
    assert core.inbox("C")["messages"] == []


def test_message_status_lists_real_readers():
    for n in ("A", "B", "C"):
        core.register(n)
    mid = core.send("A", "all", "hi")
    core.inbox("B", consume=True)
    assert {r["recipient"] for r in core.message_status(mid)["readers"]} == {"B"}
    core.inbox("C", consume=True)
    assert {r["recipient"] for r in core.message_status(mid)["readers"]} == {"B", "C"}


def test_message_status_unknown_id_raises():
    with pytest.raises(ValueError):
        core.message_status(999)
