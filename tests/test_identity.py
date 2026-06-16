"""T0.3 -- session-bound identity in the stdio server layer."""

import inspect

import pytest

from claude_bus import core, server

pytestmark = pytest.mark.integration


def test_send_before_register_fails():
    with pytest.raises(ValueError) as exc:
        server.send("B", "hi")
    assert "register first" in str(exc.value)


def test_inbox_before_register_fails():
    with pytest.raises(ValueError):
        server.inbox()


def test_claim_before_register_fails():
    with pytest.raises(ValueError):
        server.claim("f.tex")


def test_whoami_before_register():
    assert "not registered" in server.whoami()


def test_register_binds_identity():
    server.register("backend", "API work")
    assert server.whoami() == "backend"


def test_send_uses_bound_identity():
    server.register("backend")
    server.send("frontend", "login ready")
    core.register("frontend")
    msgs = core.inbox("frontend")["messages"]
    assert msgs[0]["from"] == "backend"
    assert msgs[0]["content"] == "login ready"


def test_sender_cannot_be_spoofed_via_argument():
    # There is simply no sender parameter to forge on the stdio send tool.
    params = inspect.signature(server.send).parameters
    assert "sender" not in params
    assert "to" in params and "content" in params


def test_claim_uses_bound_identity():
    server.register("editor")
    server.claim("Cap_4.tex")
    assert core.list_claims()[0]["owner"] == "editor"


def test_inbox_returns_messages_and_pending():
    server.register("me")
    core.register("other")
    core.send("other", "me", "ping")
    result = server.inbox()
    assert result["messages"][0]["content"] == "ping"
    assert result["pending_count"] == 0
