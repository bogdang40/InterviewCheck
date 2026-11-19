"""Tests for M19-W2 customizable and redacted print reports."""
import html
import json
import re

from fastapi.testclient import TestClient
import pytest

from api import exports, store
from api.main import app

PASSAGE = "Write-ahead logs append every state change before data pages flush to disk."


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_OPERATOR_EMAIL",
                "INTERVIEWCHECK_PUBLIC_ORIGIN", "INTERVIEWCHECK_PRODUCTION"):
        monkeypatch.delenv(key, raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        yield client


def _seed_session(
    client,
    *,
    candidate="Ada Lovelace",
    role="Staff Engineer",
    policy="Standard closed-book policy",
    question="How does WAL durability work?",
    answer=f"{PASSAGE} Candidate secret phrase alpha-99.",
    note="Verified WAL sequence.",
    permitted_text="Permitted guide text for interview.",
    ref_text=PASSAGE,
    session_legacy=None,
    answer_legacy=None,
):
    res = client.post("/api/sessions", json={
        "candidate": candidate, "role": role, "policy": policy, "consent": True,
        "permitted_sources": [{"label": "Role Guide", "text": permitted_text}],
    })
    res.raise_for_status()
    sid = res.json()["id"]
    ans = client.post(f"/api/sessions/{sid}/answers", json={
        "question": question, "answer": answer,
        "references": [{"label": "WAL Reference", "text": ref_text}],
    })
    ans.raise_for_status()
    aid = ans.json()["id"]
    client.patch(f"/api/sessions/{sid}/answers/{aid}", json={"disposition": "explained", "note": note}).raise_for_status()
    if session_legacy is not None or answer_legacy is not None:
        with store.connection(write=True) as db:
            if session_legacy is not None:
                db.execute("UPDATE sessions SET legacy=? WHERE id=?", (json.dumps(session_legacy), sid))
            if answer_legacy is not None:
                db.execute("UPDATE answers SET legacy=? WHERE id=?", (json.dumps(answer_legacy), aid))
    return sid, aid


def _install_m19_tables(db):
    db.executescript("""
        CREATE TABLE IF NOT EXISTS session_scorecards (
          session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
          criterion_id TEXT NOT NULL, criterion_label TEXT NOT NULL,
          weight INTEGER NOT NULL DEFAULT 1, rating INTEGER NOT NULL CHECK(rating BETWEEN 1 AND 5),
          rationale TEXT NOT NULL DEFAULT '', updated_by TEXT NOT NULL, updated_at TEXT NOT NULL,
          PRIMARY KEY (session_id, criterion_id)
        );
        CREATE TABLE IF NOT EXISTS session_handoff_notes (
          id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
          author_email TEXT NOT NULL, category TEXT NOT NULL CHECK(category IN ('observation','follow_up','decision','concern')),
          body TEXT NOT NULL, created_at TEXT NOT NULL
        );
    """)


def test_print_default_backward_compatible(env):
    sid, _ = _seed_session(
        env,
        session_legacy={"nativeVersion": 2, "legacySessionTag": "legacy-sess-marker"},
        answer_legacy={"nativeScore": 88, "legacyAnswerTag": "legacy-ans-marker"},
    )
    resp = env.get(f"/api/sessions/{sid}/print")
    assert resp.status_code == 200
    assert resp.headers["cache-control"] == "no-store"
    csp = resp.headers["content-security-policy"]
    assert exports.PRINT_STYLE_HASH in csp and "script-src 'self'" in csp and "'unsafe-inline'" not in csp
    assert "onclick=" not in resp.text
    assert '<script src="/api/exports/print.js" defer></script>' in resp.text
    assert len(re.findall(r"<script\b", resp.text, re.I)) == 1
    for expected in ("Ada Lovelace", "Permitted guide text for interview.", "WAL Reference",
                     "Candidate secret phrase alpha-99.", "explained", "Verified WAL sequence.",
                     "legacy-sess-marker", "legacy-ans-marker"):
        assert expected in resp.text
    assert "Rubric scorecard" not in resp.text and "Panel handoff notes" not in resp.text


def test_print_toggle_include_sources_and_legacy_false(env):
    sid, _ = _seed_session(
        env,
        permitted_text="Unique permitted body token-11.",
        ref_text=f"{PASSAGE} Unique comparison source token-22.",
        session_legacy={"tag": "legacy-session-only"},
        answer_legacy={"tag": "legacy-answer-only"},
    )
    no_src = env.get(f"/api/sessions/{sid}/print", params={"include_sources": "false"})
    assert no_src.status_code == 200
    assert "Unique permitted body token-11." not in no_src.text
    assert "Unique comparison source token-22." not in no_src.text
    assert "Candidate secret phrase alpha-99." in no_src.text and "explained" in no_src.text

    no_legacy = env.get(f"/api/sessions/{sid}/print", params={"include_legacy": "false"})
    assert no_legacy.status_code == 200
    for omitted in ("Original native session record", "Original native answer record", "legacy-session-only", "legacy-answer-only"):
        assert omitted not in no_legacy.text


def test_print_scorecard_with_and_without_table(env):
    sid, _ = _seed_session(env)
    with store.connection(write=True) as db:
        db.execute("DROP TABLE IF EXISTS session_scorecards")
    pre_m19 = env.get(f"/api/sessions/{sid}/print", params={"include_scorecard": "true"})
    assert pre_m19.status_code == 200 and "Rubric scorecard" not in pre_m19.text

    with store.connection(write=True) as db:
        _install_m19_tables(db)
        db.execute(
            "INSERT INTO session_scorecards(session_id,criterion_id,criterion_label,weight,rating,rationale,updated_by,updated_at) VALUES (?,?,?,?,?,?,?,?)",
            (sid, "c1", "System Design", 2, 5, "Clear WAL failure model.", "lead@example.test", "2026-11-19T00:00:00Z"),
        )
        db.execute(
            "INSERT INTO session_scorecards(session_id,criterion_id,criterion_label,weight,rating,rationale,updated_by,updated_at) VALUES (?,?,?,?,?,?,?,?)",
            (sid, "c2", "Communication", 1, 2, "Needed prompting on edge cases.", "lead@example.test", "2026-11-19T00:00:00Z"),
        )

    with_sc = env.get(f"/api/sessions/{sid}/print", params={"include_scorecard": "true"})
    assert with_sc.status_code == 200
    for expected in ("Rubric scorecard", "80.0%", "System Design (weight 2)", "Rating: 5/5 - Clear WAL failure model."):
        assert expected in with_sc.text

    without_sc = env.get(f"/api/sessions/{sid}/print", params={"include_scorecard": "false"})
    assert without_sc.status_code == 200
    assert "Rubric scorecard" not in without_sc.text and "Clear WAL failure model." not in without_sc.text


def test_print_handoff_notes_defensive_and_opt_in(env):
    sid, _ = _seed_session(env)
    with store.connection(write=True) as db:
        db.execute("DROP TABLE IF EXISTS session_handoff_notes")
    pre_m19 = env.get(f"/api/sessions/{sid}/print", params={"include_handoff_notes": "true"})
    assert pre_m19.status_code == 200 and "Panel handoff notes" not in pre_m19.text

    with store.connection(write=True) as db:
        _install_m19_tables(db)

    empty_notes = env.get(f"/api/sessions/{sid}/print", params={"include_handoff_notes": "true"})
    assert empty_notes.status_code == 200 and "No handoff notes recorded." in empty_notes.text

    with store.connection(write=True) as db:
        db.execute(
            "INSERT INTO session_handoff_notes(id,session_id,author_email,category,body,created_at) VALUES (?,?,?,?,?,?)",
            ("n1", sid, "panel2@example.test", "follow_up", "Probe distributed consensus next round.", "2026-11-19T01:00:00Z"),
        )

    default_view = env.get(f"/api/sessions/{sid}/print")
    assert default_view.status_code == 200
    assert "Panel handoff notes" not in default_view.text and "Probe distributed consensus next round." not in default_view.text

    included = env.get(f"/api/sessions/{sid}/print", params={"include_handoff_notes": "true"})
    assert included.status_code == 200
    assert "Panel handoff notes" in included.text and "follow_up by panel2@example.test" in included.text
    assert "Probe distributed consensus next round." in included.text


def test_print_redact_candidate_omits_identity_and_raw_answer(env):
    sid, _ = _seed_session(
        env,
        candidate="Grace Hopper",
        answer=f"{PASSAGE} Confidential candidate phrase zebra-77.",
        session_legacy={"candidate": "Grace Hopper", "secret": "legacy-leak-88"},
        answer_legacy={"answer": "Confidential candidate phrase zebra-77."},
    )
    with store.connection(write=True) as db:
        _install_m19_tables(db)
        db.execute(
            "INSERT INTO session_scorecards(session_id,criterion_id,criterion_label,weight,rating,rationale,updated_by,updated_at) VALUES (?,?,?,?,?,?,?,?)",
            (sid, "c1", "Storage Internals", 1, 4, "Strong tradeoff analysis.", "lead@example.test", "2026-11-19T00:00:00Z"),
        )

    redacted = env.get(f"/api/sessions/{sid}/print", params={"redact_candidate": "true"})
    assert redacted.status_code == 200 and redacted.headers["cache-control"] == "no-store"
    assert exports.PRINT_STYLE_HASH in redacted.headers["content-security-policy"]
    assert "Candidate [Redacted]" in redacted.text
    for omitted in ("Grace Hopper", "Confidential candidate phrase zebra-77.", "Candidate excerpt",
                    "Captured answer", "Follow up", "legacy-leak-88"):
        assert omitted not in redacted.text
    for kept in ("How does WAL durability work?", "Matched passages", "explained", "Rubric scorecard", "80.0%"):
        assert kept in redacted.text

    redacted_no_src = env.get(f"/api/sessions/{sid}/print", params={"redact_candidate": "true", "include_sources": "false"})
    assert redacted_no_src.status_code == 200 and PASSAGE not in redacted_no_src.text


def test_print_xss_escaping_and_csp_on_all_sections(env):
    xss = '<script>alert(1)</script><img src=x onerror="alert(2)">'
    sid, _ = _seed_session(
        env, candidate=xss, role=xss, policy=xss, question=xss,
        answer=f"{PASSAGE} {xss}", note=xss, permitted_text=xss, ref_text=f"{PASSAGE} {xss}",
    )
    with store.connection(write=True) as db:
        _install_m19_tables(db)
        db.execute(
            "INSERT INTO session_scorecards(session_id,criterion_id,criterion_label,weight,rating,rationale,updated_by,updated_at) VALUES (?,?,?,?,?,?,?,?)",
            (sid, "c1", xss, 1, 3, xss, xss, "2026-11-19T00:00:00Z"),
        )
        db.execute(
            "INSERT INTO session_handoff_notes(id,session_id,author_email,category,body,created_at) VALUES (?,?,?,?,?,?)",
            ("n-xss", sid, xss, "concern", xss, "2026-11-19T01:00:00Z"),
        )

    escaped = html.escape(xss, quote=True)
    for params in ({}, {"include_handoff_notes": "true"}, {"redact_candidate": "true", "include_handoff_notes": "true"}):
        resp = env.get(f"/api/sessions/{sid}/print", params=params)
        assert resp.status_code == 200 and resp.headers["cache-control"] == "no-store"
        assert exports.PRINT_STYLE_HASH in resp.headers["content-security-policy"]
        assert xss not in resp.text and escaped in resp.text and "onclick=" not in resp.text
        assert len(re.findall(r"<script\b", resp.text, re.I)) == 1
