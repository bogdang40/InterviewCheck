"""Tests for M14-W1 cross-candidate comparison matrix and printable/Markdown dossiers."""
import json
import re
from uuid import uuid4

from fastapi.testclient import TestClient
import pytest

from api import store
from api.exports import PRINT_STYLE_HASH
from api.main import app

PASSAGE = "The oldest active snapshot pins tombstones across every replica until compaction completes"


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_OPERATOR_EMAIL", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(key, raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def _create_role(client, *, name="Distributed Systems", questions=None):
    resp = client.post("/api/roles", json={
        "name": name, "description": "Backend systems", "policy": "No external assistance.",
        "questions": questions if questions is not None else ["Explain Raft.", "Explain MVCC."],
    })
    resp.raise_for_status()
    return resp.json()


def _create_session(client, *, candidate="Ada", role="Distributed Systems", role_id=None, policy="No external assistance."):
    payload = {"candidate": candidate, "role": role, "policy": policy, "consent": True}
    if role_id is not None:
        payload["role_id"] = role_id
    resp = client.post("/api/sessions", json=payload)
    resp.raise_for_status()
    return resp.json()


def _add_answer(client, sid, *, question="Explain Raft.", answer=PASSAGE, slot=None, match=False):
    payload = {"question": question, "answer": answer, "references": [{"label": "Ref", "text": PASSAGE}] if match else []}
    if slot is not None:
        payload["planned_slot"] = slot
    resp = client.post(f"/api/sessions/{sid}/answers", json=payload)
    resp.raise_for_status()
    return resp.json()


def test_compare_2_to_6_candidates_slot_alignment_and_counts(client):
    role = _create_role(client, questions=["Explain Raft.", "Explain MVCC."])
    s1 = _create_session(client, candidate="Ada", role=role["name"], role_id=role["id"])
    s2 = _create_session(client, candidate="Grace", role=role["name"], role_id=role["id"])
    a11 = _add_answer(client, s1["id"], question="Explain Raft.", answer=PASSAGE, slot=1, match=True)
    _add_answer(client, s1["id"], question="Explain MVCC.", answer="Snapshot isolation keeps old tuples.", slot=2)
    a1u = _add_answer(client, s1["id"], question="Follow up?", answer="We monitor lag.")
    a21 = _add_answer(client, s2["id"], question="Explain Raft.", answer=PASSAGE, slot=1, match=True)
    client.patch(f"/api/sessions/{s1['id']}/answers/{a11['id']}", json={"disposition": "explained", "note": "Clear"}).raise_for_status()
    client.patch(f"/api/sessions/{s1['id']}/answers/{a1u['id']}", json={"disposition": "disclosed", "note": "Used notes"}).raise_for_status()
    client.patch(f"/api/sessions/{s2['id']}/answers/{a21['id']}", json={"disposition": "unresolved", "note": "Needs review"}).raise_for_status()
    client.post(f"/api/sessions/{s2['id']}/finish").raise_for_status()

    s3 = _create_session(client, candidate="Lin", role="Other", policy="Open book")
    with store.connection(write=True) as db:
        db.execute("UPDATE sessions SET consent=0 WHERE id=?", (s3["id"],))

    res = client.post("/api/interviews/compare", json={"session_ids": [s1["id"], s2["id"], s3["id"]]})
    assert res.status_code == 200
    body = res.json()
    assert [s["id"] for s in body["sessions"]] == [s1["id"], s2["id"], s3["id"]]
    assert [s["lifecycle"] for s in body["sessions"]] == ["active", "finished", "archived"]
    assert body["sessions"][0]["counts"] == {
        "match": 1, "no_match": 0, "insufficient": 2, "pending": 1, "explained": 1, "unresolved": 0, "disclosed": 1,
    }
    assert body["sessions"][1]["counts"]["unresolved"] == 1
    assert [row["slot"] for row in body["slots"]] == [1, 2, "unslotted"]
    assert body["slots"][0]["planned_question"] == "Explain Raft."
    assert body["slots"][0]["cells"][s1["id"]]["passage_count"] == 1
    assert body["slots"][1]["cells"][s2["id"]] is None
    assert body["slots"][2]["cells"][s1["id"]]["answer_id"] == a1u["id"]
    assert "excerpt" not in body["slots"][0]["cells"][s1["id"]]
    assert "note" not in body["slots"][0]["cells"][s1["id"]]

    six_ids = [s1["id"], s2["id"], s3["id"]] + [_create_session(client, candidate=f"C{i}")["id"] for i in range(3)]
    res6 = client.post("/api/interviews/compare", json={"session_ids": six_ids})
    assert res6.status_code == 200 and len(res6.json()["sessions"]) == 6


def test_compare_validation_422_and_missing_trashed_404(client):
    s1 = _create_session(client, candidate="One")["id"]
    s2 = _create_session(client, candidate="Two")["id"]
    extra = [_create_session(client, candidate=f"E{i}")["id"] for i in range(5)]

    for bad in ([], [s1], [s1, s2, *extra], [s1, s1], ["not-a-uuid", s2]):
        assert client.post("/api/interviews/compare", json={"session_ids": bad}).status_code == 422
    assert client.post("/api/interviews/compare", json={"session_ids": [s1, s2], "extra": 1}).status_code == 422
    assert client.post("/api/interviews/compare/dossier", json={"session_ids": [s1, s2], "format": "pdf"}).status_code == 422

    for bad_ids in (s1, f"{s1},{s1}", f"{s1},, {s2}", ",".join([s1, s2, *extra]), f"bad,{s2}"):
        assert client.get(f"/api/interviews/compare/print?ids={bad_ids}").status_code == 422

    missing = str(uuid4())
    assert client.post("/api/interviews/compare", json={"session_ids": [s1, missing]}).status_code == 404
    assert client.post("/api/interviews/compare/dossier", json={"session_ids": [s1, missing], "format": "markdown"}).status_code == 404
    assert client.get(f"/api/interviews/compare/print?ids={s1},{missing}").status_code == 404

    trashed = client.post(f"/api/sessions/{s2}/trash").json()
    assert client.post("/api/interviews/compare", json={"session_ids": [s1, s2]}).status_code == 404
    assert client.post("/api/interviews/compare/dossier", json={"session_ids": [s1, s2], "format": "html"}).status_code == 404
    assert client.get(f"/api/interviews/compare/print?ids={s1},{s2}").status_code == 404

    client.post(f"/api/trash/{s2}/restore", json={"operation_version": trashed["operation_version"]}).raise_for_status()
    assert client.post("/api/interviews/compare", json={"session_ids": [s1, s2]}).status_code == 200


def test_excerpt_cap_and_note_gating_across_json_markdown_html(client):
    s1 = _create_session(client, candidate="Ada")["id"]
    s2 = _create_session(client, candidate="Grace")["id"]
    long_answer = "PREFIX_SECRET_MARKER " + ("x" * 300)
    note_secret = "CONFIDENTIAL_NOTE_MARKER"
    ans = _add_answer(client, s1, question="Q1?", answer=long_answer)
    client.patch(f"/api/sessions/{s1}/answers/{ans['id']}", json={"disposition": "explained", "note": note_secret}).raise_for_status()

    gated_json = client.post("/api/interviews/compare", json={"session_ids": [s1, s2]}).json()
    cell_gated = gated_json["slots"][0]["cells"][s1]
    assert "excerpt" not in cell_gated and "note" not in cell_gated

    gated_md = client.post("/api/interviews/compare/dossier", json={"session_ids": [s1, s2], "format": "markdown"}).text
    gated_html = client.get(f"/api/interviews/compare/print?ids={s1},{s2}").text
    for text in (gated_md, gated_html):
        assert "PREFIX_SECRET_MARKER" not in text and note_secret not in text

    open_json = client.post("/api/interviews/compare", json={"session_ids": [s1, s2], "include_excerpts": True, "include_notes": True}).json()
    cell_open = open_json["slots"][0]["cells"][s1]
    assert len(cell_open["excerpt"]) == 240 and cell_open["excerpt"].endswith("…")
    assert cell_open["excerpt"].startswith("PREFIX_SECRET_MARKER")
    assert cell_open["note"] == note_secret

    open_md = client.post("/api/interviews/compare/dossier", json={"session_ids": [s1, s2], "include_excerpts": True, "include_notes": True, "format": "markdown"}).text
    open_html = client.get(f"/api/interviews/compare/print?ids={s1},{s2}&include_excerpts=true&include_notes=true").text
    for text in (open_md, open_html):
        assert "PREFIX_SECRET_MARKER" in text and note_secret in text


def test_markdown_and_html_dossier_escaping_csp_and_headers(client):
    xss = '<script>alert(1)</script>" onmouseover="alert(2)'
    md_evil = "[phish](https://evil.test) | pipe"
    s1 = _create_session(client, candidate=f"{xss} {md_evil}", role="Eng")["id"]
    s2 = _create_session(client, candidate="Safe", role="Eng")["id"]
    ans = _add_answer(client, s1, question=xss, answer=f"Answer {xss}")
    client.patch(f"/api/sessions/{s1}/answers/{ans['id']}", json={"disposition": "explained", "note": xss}).raise_for_status()

    md = client.post("/api/interviews/compare/dossier", json={
        "session_ids": [s1, s2], "include_excerpts": True, "include_notes": True, "format": "markdown",
    })
    assert md.status_code == 200
    assert md.headers["content-disposition"] == 'attachment; filename="candidate-comparison.md"'
    assert md.headers["cache-control"] == "no-store"
    assert md.headers["content-type"].startswith("text/markdown")
    unindented = "\n".join(line for line in md.text.splitlines() if not line.startswith("    "))
    assert "<script>alert(1)</script>" not in unindented
    assert "[phish](https://evil.test)" not in unindented
    assert "\\<script\\>alert\\(1\\)\\</script\\>" in unindented
    assert "\\| pipe" in unindented and "    <script>alert(1)</script>" in md.text

    for resp in (
        client.post("/api/interviews/compare/dossier", json={"session_ids": [s1, s2], "include_excerpts": True, "include_notes": True, "format": "html"}),
        client.get(f"/api/interviews/compare/print?ids={s1},{s2}&include_excerpts=true&include_notes=true"),
    ):
        assert resp.status_code == 200
        assert resp.headers["cache-control"] == "no-store"
        assert resp.headers["content-type"].startswith("text/html")
        assert "onclick=" not in resp.text
        assert "<script>alert(1)</script>" not in resp.text
        assert "&lt;script&gt;alert(1)&lt;/script&gt;" in resp.text
        assert '<script src="/api/exports/print.js" defer></script>' in resp.text
        assert len(re.findall(r"<script\b", resp.text)) == 1
        csp = resp.headers["content-security-policy"]
        assert "script-src 'self'" in csp and f"'{PRINT_STYLE_HASH}'" in csp and "'unsafe-inline'" not in csp


def test_compare_auth_and_csrf_protection(client, monkeypatch):
    s1 = _create_session(client, candidate="One")["id"]
    s2 = _create_session(client, candidate="Two")["id"]

    with TestClient(app, base_url="http://127.0.0.1") as raw:
        assert raw.post("/api/interviews/compare", json={"session_ids": [s1, s2]}).status_code == 403
        assert raw.post("/api/interviews/compare/dossier", json={"session_ids": [s1, s2], "format": "markdown"}).status_code == 403

    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "http://127.0.0.1:8787")
    assert client.post("/api/interviews/compare", json={"session_ids": [s1, s2]}).status_code == 401
    assert client.post("/api/interviews/compare/dossier", json={"session_ids": [s1, s2], "format": "html"}).status_code == 401
    assert client.get(f"/api/interviews/compare/print?ids={s1},{s2}").status_code == 401


def test_rubric_criteria_pre_and_post_m12_schema(client):
    role_a = _create_role(client, name="Role A")
    role_b = _create_role(client, name="Role B")
    sa1 = _create_session(client, candidate="A1", role=role_a["name"], role_id=role_a["id"])["id"]
    sa2 = _create_session(client, candidate="A2", role=role_a["name"], role_id=role_a["id"])["id"]
    sb1 = _create_session(client, candidate="B1", role=role_b["name"], role_id=role_b["id"])["id"]

    pre = client.post("/api/interviews/compare", json={"session_ids": [sa1, sa2]})
    assert pre.status_code == 200 and pre.json()["rubric_criteria"] == []

    rubric = [{"id": "r1", "criterion": "Fault tolerance", "weight": 40, "expected_signals": ["Quorum"], "red_flags": ["Single point of failure"]}]
    with store.connection(write=True) as db:
        cols = {col[1] for col in db.execute("PRAGMA table_info(roles)")}
        if "rubric_json" not in cols:
            db.execute("ALTER TABLE roles ADD COLUMN rubric_json TEXT NOT NULL DEFAULT '[]'")
        db.execute("UPDATE roles SET rubric_json=? WHERE id=?", (json.dumps(rubric), role_a["id"]))

    shared = client.post("/api/interviews/compare", json={"session_ids": [sa1, sa2]})
    assert shared.status_code == 200
    assert shared.json()["rubric_criteria"] == [{
        "criterion": "Fault tolerance", "weight": 40,
        "expected_signals": ["Quorum"], "red_flags": ["Single point of failure"],
    }]
    assert "Fault tolerance" in client.get(f"/api/interviews/compare/print?ids={sa1},{sa2}").text
    assert "Fault tolerance" in client.post("/api/interviews/compare/dossier", json={"session_ids": [sa1, sa2], "format": "markdown"}).text

    mixed = client.post("/api/interviews/compare", json={"session_ids": [sa1, sb1]})
    assert mixed.status_code == 200 and mixed.json()["rubric_criteria"] == []
