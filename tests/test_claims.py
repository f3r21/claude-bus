"""T1.1 -- advisory file soft-locks and ownership overlap."""

import time

import pytest

from claude_bus import core

pytestmark = pytest.mark.unit


def test_claim_blocks_other_agent():
    core.claim("Cap_4.tex", "A")
    with pytest.raises(ValueError) as exc:
        core.claim("Cap_4.tex", "B")
    assert "A" in str(exc.value)


def test_owner_can_refresh_own_claim():
    core.claim("f.tex", "A", ttl=10)
    core.claim("f.tex", "A", ttl=20)  # refresh must not raise
    claims = core.list_claims()
    assert len(claims) == 1
    assert claims[0]["owner"] == "A"


def test_expired_claim_can_be_taken_over():
    core.claim("f.tex", "A", ttl=0)
    time.sleep(0.01)
    core.claim("f.tex", "B")
    assert core.list_claims()[0]["owner"] == "B"


def test_release_removes_claim_and_frees_path():
    core.claim("f.tex", "A")
    core.release("f.tex", "A")
    assert core.list_claims() == []
    core.claim("f.tex", "B")
    assert core.list_claims()[0]["owner"] == "B"


def test_release_by_non_owner_rejected():
    core.claim("f.tex", "A")
    with pytest.raises(ValueError):
        core.release("f.tex", "B")


def test_list_claims_excludes_expired():
    core.claim("a.tex", "A", ttl=1000)
    core.claim("b.tex", "B", ttl=0)
    time.sleep(0.01)
    assert {c["path"] for c in core.list_claims()} == {"a.tex"}


def test_agents_flags_overlapping_globs():
    core.register("figs", owns=["figuras/*"])
    core.register("cons", owns=["figuras/consistencia.tex"])
    by_name = {a["name"]: a for a in core.agents()}
    assert "cons" in by_name["figs"]["overlaps"]
    assert "figs" in by_name["cons"]["overlaps"]


def test_agents_no_overlap_when_disjoint():
    core.register("api", owns=["src/api/*"])
    core.register("web", owns=["src/web/*"])
    by_name = {a["name"]: a for a in core.agents()}
    assert by_name["api"]["overlaps"] == []
    assert by_name["web"]["overlaps"] == []


def test_claim_creates_overlap_with_glob_owner():
    core.register("owner_glob", owns=["docs/*"])
    core.register("claimer")
    core.claim("docs/intro.tex", "claimer")
    by_name = {a["name"]: a for a in core.agents()}
    assert "claimer" in by_name["owner_glob"]["overlaps"]
