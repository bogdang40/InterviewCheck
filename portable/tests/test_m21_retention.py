"""Tests for M21-W1 data retention policies, PII anonymization, FTS scrub, and trash purge."""
from contextlib import closing
from datetime import datetime, timedelta, timezone
import json
import sqlite3
from unittest.mock import AsyncMock
from uuid import uuid4

from fastapi import HTTPException
from fastapi.testclient import TestClient
import pytest

from api import access, account_db, rate_limit, retention_policy, store
from api.main import app


def _seed_user(*, email: str, role: str = "admin") -> str:
    uid, ts = str(uuid4()), account_db.now()
    with account_db.connection(write=True) as db:
        db.execute(
            "INSERT INTO users(id, email, password_hash, role, disabled, created_at, updated_at) VALUES (?,?,?,?,0,?,?)",
            (uid, email, account_db.DECOY, role, ts, ts),
        )
        return account_db.issue(db, uid, "pytest")


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_OPERATOR_EMAIL", "INTERVIEWCHECK_PUBLIC_ORIGIN", "INTERVIEWCHECK_PRODUCTION"):
        monkeypatch.delenv(key, raising=False)
    rate_limit.reset_all()
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def _create_full_session(
    client: TestClient,
    *,
    candidate: str,
    consent: bool = True,
    finished: bool = True,
    age_days: int = 120,
    with_scorecard: bool = True,
) -> dict[str, str]:
    source_text = "Hydraulic pressure relief valve calibrated to four hundred kilopascals during load testing."
    answer_text = (
        f"Candidate {candidate} confirmed that hydraulic pressure relief valve calibrated to "
        "four hundred kilopascals during load testing prevented cavitation."
    )
    if consent:
        res = client.post(
            "/api/sessions",
            json={"candidate": candidate, "role": "Reliability Engineer", "policy": "No external help.", "consent": True},
        )
        res.raise_for_status()
        sid = res.json()["id"]
        ans = client.post(
            f"/api/sessions/{sid}/answers",
            json={"question": "Describe valve calibration.", "answer": answer_text, "references": [{"label": "Manual", "text": source_text}]},
        ).json()
        aid = ans["id"]
        client.patch(f"/api/sessions/{sid}/answers/{aid}", json={"disposition": "explained", "note": f"Private note for {candidate}"}).raise_for_status()
        if finished:
            client.post(f"/api/sessions/{sid}/finish").raise_for_status()
        with store.connection(write=True) as db:
            db.execute(
                "INSERT INTO session_drafts(session_id, id, question, answer, refs, revision, updated_at) VALUES (?,?,?,?,?,1,?)",
                (sid, str(uuid4()), "Follow up", f"Draft PII for {candidate}", "[]", store.timestamp()),
            )
    else:
        sid, aid = str(uuid4()), str(uuid4())
        with store.connection(write=True) as db:
            db.execute("INSERT INTO sessions(id, candidate, role, policy, consent, created_at, legacy) VALUES (?,?,?,?,0,?,?)",
                       (sid, candidate, "Reliability Engineer", "", store.timestamp(), '{"raw":"pii"}'))
            db.execute("INSERT INTO session_context(session_id, questions, permitted_sources) VALUES (?,?,?)", (sid, "[]", "[]"))
            db.execute("INSERT INTO answers(id, session_id, question, answer, refs, result, status, disposition, note, legacy, import_origin) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                       (aid, sid, "Q", answer_text, "[]", json.dumps({"status": "match", "passages": [{"label": "Manual", "words": 8, "answer_excerpt": "hydraulic pressure relief"}]}),
                        "match", "pending", f"Private note for {candidate}", '{"old":1}', '{"src":"txt"}'))

    if with_scorecard:
        with store.connection(write=True) as db:
            db.execute(
                "INSERT INTO session_scorecards(session_id, criterion_id, criterion_label, weight, rating, rationale, updated_by, updated_at) VALUES (?,?,?,?,?,?,?,?)",
                (sid, "c1", "Safety", 3, 4, f"Scorecard rationale mentioning {candidate}", "lead@example.test", store.timestamp()),
            )
            db.execute(
                "INSERT INTO session_handoff_notes(id, session_id, author_email, category, body, created_at) VALUES (?,?,?,?,?,?)",
                (str(uuid4()), sid, "lead@example.test", "observation", f"Handoff note for {candidate}", store.timestamp()),
            )

    old_ts = (datetime.now(timezone.utc) - timedelta(days=age_days)).isoformat()
    with store.connection(write=True) as db:
        db.execute("UPDATE sessions SET created_at=?, legacy=? WHERE id=?", (old_ts, '{"legacy_name":"' + candidate + '"}', sid))
        if finished and consent:
            db.execute("UPDATE session_context SET ended_at=? WHERE session_id=?", (old_ts, sid))
        db.execute("UPDATE answers SET legacy=?, import_origin=? WHERE id=?", ('{"raw":"ans"}', '{"origin":"csv"}', aid))
        db.execute("INSERT INTO transcript_imports(id, session_id, payload_sha256, answer_ids) VALUES (?,?,?,?)",
                   (str(uuid4()), sid, "a" * 64, json.dumps([aid])))
    return {"sid": sid, "aid": aid}


@pytest.mark.parametrize("mode", [None, "embedded", "remote"])
def test_retention_auth_csrf_and_policy_validation(env, monkeypatch, mode):
    payload = {"anonymize_after_days": 60, "purge_trashed_after_days": 14, "preserve_scorecard_aggregates": True, "enabled": True}
    if mode == "embedded":
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    elif mode == "remote":
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "remote")
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "https://accounts.example.invalid")
        monkeypatch.setattr(access, "upstream", AsyncMock(side_effect=HTTPException(401, "Expired")))

    assert env.get("/api/admin/compliance/retention").status_code == 401
    assert env.put("/api/admin/compliance/retention", json=payload).status_code == 401
    assert env.post("/api/admin/compliance/retention/run", json={"dry_run": True}).status_code == 401

    forged = {"Cookie": f"{access.COOKIE}=mm_forged_cookie_value_12345678901234567890"}
    assert env.get("/api/admin/compliance/retention", headers=forged).status_code == 401

    if mode == "remote":
        monkeypatch.setattr(access, "upstream", AsyncMock(return_value={
            "user": {"id": str(uuid4()), "email": "u@example.invalid", "role": "user", "disabled": False},
            "entitlement": {"active": True},
        }))
        user_hdr = {"Cookie": f"{access.COOKIE}=remote-user"}
    else:
        user_hdr = {"Cookie": f"{access.COOKIE}={_seed_user(email='u@example.invalid', role='user')}"}

    assert env.get("/api/admin/compliance/retention", headers=user_hdr).status_code == 403
    assert env.put("/api/admin/compliance/retention", json=payload, headers=user_hdr).status_code == 403
    assert env.post("/api/admin/compliance/retention/run", json={"dry_run": True}, headers=user_hdr).status_code == 403

    if mode == "remote":
        monkeypatch.setattr(access, "upstream", AsyncMock(return_value={
            "user": {"id": str(uuid4()), "email": "admin@example.invalid", "role": "admin", "disabled": False},
            "entitlement": {"active": True},
        }))
        admin_tok = "remote-admin"
    else:
        admin_tok = _seed_user(email="admin@example.invalid", role="admin")

    with TestClient(app, base_url="http://127.0.0.1") as raw:
        raw.cookies.set(access.COOKIE, admin_tok)
        assert raw.put("/api/admin/compliance/retention", json=payload).status_code == 403
        assert raw.post("/api/admin/compliance/retention/run", json={"dry_run": True}).status_code == 403

    admin_hdr = {"Cookie": f"{access.COOKIE}={admin_tok}"}
    initial = env.get("/api/admin/compliance/retention", headers=admin_hdr)
    assert initial.status_code == 200
    assert initial.json()["policy"]["anonymize_after_days"] == 90
    assert initial.json()["policy"]["enabled"] is False
    assert initial.json()["runs"] == []

    for bad in (
        {"anonymize_after_days": -1, "purge_trashed_after_days": 30},
        {"anonymize_after_days": 3651, "purge_trashed_after_days": 30},
        {"anonymize_after_days": "30", "purge_trashed_after_days": 30},
        {"anonymize_after_days": 30, "purge_trashed_after_days": 30, "unexpected": True},
        {},
    ):
        assert env.put("/api/admin/compliance/retention", json=bad, headers=admin_hdr).status_code == 422

    updated = env.put("/api/admin/compliance/retention", json=payload, headers=admin_hdr)
    assert updated.status_code == 200
    assert updated.json()["policy"]["anonymize_after_days"] == 60
    assert updated.json()["policy"]["updated_by"] == "admin@example.invalid"

    if mode == "remote":
        with store.connection() as db:
            row = db.execute("SELECT action, model_id FROM model_audit ORDER BY id DESC LIMIT 1").fetchone()
            assert row["action"] == "admin.compliance.retention_policy" and row["model_id"] == "default"
    else:
        with account_db.connection() as adb:
            assert adb.execute("PRAGMA user_version").fetchone()[0] == 8
            assert account_db.verify_audit_chain(adb)["ok"] is True
            row = adb.execute("SELECT action, target_user_id FROM audit_log ORDER BY id DESC LIMIT 1").fetchone()
            assert row["action"] == "admin.compliance.retention_policy" and row["target_user_id"] == "default"


def test_dry_run_vs_live_anonymization_and_fts_search_scrub(env):
    admin_hdr = {"Cookie": f"{access.COOKIE}={_seed_user(email='compliance@example.test', role='admin')}"}
    s_fin = _create_full_session(env, candidate="Zaphod Beeblebrox", consent=True, finished=True, age_days=120)
    s_noconsent = _create_full_session(env, candidate="Trillian Astra", consent=False, finished=False, age_days=120)
    s_recent = _create_full_session(env, candidate="Arthur Dent", consent=True, finished=True, age_days=10)
    s_active = _create_full_session(env, candidate="Ford Prefect", consent=True, finished=False, age_days=120)
    s_trashed = _create_full_session(env, candidate="Marvin Android", consent=True, finished=True, age_days=120)
    env.post(f"/api/sessions/{s_trashed['sid']}/trash").raise_for_status()

    assert env.post("/api/search", json={"query": "Zaphod Beeblebrox"}).json()["items"][0]["session_id"] == s_fin["sid"]

    env.put(
        "/api/admin/compliance/retention",
        json={"anonymize_after_days": 90, "purge_trashed_after_days": 30, "preserve_scorecard_aggregates": True, "enabled": True},
        headers=admin_hdr,
    ).raise_for_status()

    dry = env.post("/api/admin/compliance/retention/run", json={"dry_run": True}, headers=admin_hdr)
    assert dry.status_code == 200
    dry_body = dry.json()
    assert dry_body["dry_run"] is True
    assert dry_body["anonymized_sessions"] == 2
    assert set(dry_body["anonymized_session_ids"]) == {s_fin["sid"], s_noconsent["sid"]}
    assert dry_body["purged_sessions"] == 0
    assert env.post("/api/search", json={"query": "Zaphod Beeblebrox"}).json()["items"]

    with account_db.connection() as adb:
        assert adb.execute("SELECT count(*) FROM audit_log WHERE action='admin.compliance.retention_run'").fetchone()[0] == 0

    live = env.post("/api/admin/compliance/retention/run", json={"dry_run": False}, headers=admin_hdr)
    assert live.status_code == 200
    live_body = live.json()
    assert live_body["dry_run"] is False
    assert live_body["anonymized_sessions"] == 2
    assert set(live_body["anonymized_session_ids"]) == {s_fin["sid"], s_noconsent["sid"]}

    # FTS5 triggers fired on UPDATE: redacted candidate names and answers no longer match /api/search.
    assert env.post("/api/search", json={"query": "Zaphod Beeblebrox"}).json()["items"] == []
    assert env.post("/api/search", json={"query": "Trillian Astra"}).json()["items"] == []
    cav_sids = {item["session_id"] for item in env.post("/api/search", json={"query": "cavitation"}).json()["items"]}
    assert cav_sids == {s_recent["sid"], s_active["sid"]}
    assert env.post("/api/search", json={"query": f"Anonymized {s_fin['sid'][:8]}"}).json()["items"][0]["session_id"] == s_fin["sid"]
    assert env.post("/api/search", json={"query": "Arthur Dent"}).json()["items"][0]["session_id"] == s_recent["sid"]
    assert env.post("/api/search", json={"query": "Ford Prefect"}).json()["items"][0]["session_id"] == s_active["sid"]

    with store.connection() as db:
        for sid in (s_fin["sid"], s_noconsent["sid"]):
            srow = db.execute("SELECT candidate, legacy FROM sessions WHERE id=?", (sid,)).fetchone()
            assert srow["candidate"] == f"Candidate [Anonymized {sid[:8]}]"
            assert srow["legacy"] is None
            arow = db.execute("SELECT answer, note, legacy, import_origin, result FROM answers WHERE session_id=?", (sid,)).fetchone()
            assert arow["answer"] == retention_policy.REDACTED_TEXT
            assert arow["note"] == "" and arow["legacy"] is None and arow["import_origin"] is None
            parsed = json.loads(arow["result"])
            assert parsed["status"] == "match"
            assert parsed["passages"][0]["label"] == "Manual"
            assert parsed["passages"][0]["words"] >= 6
            assert parsed["passages"][0]["answer_excerpt"] == retention_policy.REDACTED_TEXT
            assert "four hundred kilopascals" not in parsed.get("follow_up", "")
            assert db.execute("SELECT count(*) FROM session_drafts WHERE session_id=?", (sid,)).fetchone()[0] == 0
            assert db.execute("SELECT count(*) FROM transcript_imports WHERE session_id=?", (sid,)).fetchone()[0] == 0
            assert db.execute("SELECT anonymized_by FROM session_anonymizations WHERE session_id=?", (sid,)).fetchone()[0] == "compliance@example.test"
            assert "Scorecard rationale" in db.execute("SELECT rationale FROM session_scorecards WHERE session_id=?", (sid,)).fetchone()[0]
            assert "Handoff note" in db.execute("SELECT body FROM session_handoff_notes WHERE session_id=?", (sid,)).fetchone()[0]
        assert db.execute("SELECT count(*) FROM session_anonymizations WHERE session_id IN (?,?)", (s_recent["sid"], s_active["sid"])).fetchone()[0] == 0

    with account_db.connection() as adb:
        assert adb.execute("SELECT count(*) FROM audit_log WHERE action='admin.compliance.retention_run'").fetchone()[0] == 1

    rerun = env.post("/api/admin/compliance/retention/run", json={"dry_run": False}, headers=admin_hdr).json()
    assert rerun["anonymized_sessions"] == 0


def test_preserve_scorecard_aggregates_toggle_and_history_cap(env):
    admin_hdr = {"Cookie": f"{access.COOKIE}={_seed_user(email='agg@example.test', role='admin')}"}
    s_strict = _create_full_session(env, candidate="Strict Scrub", consent=True, finished=True, age_days=120)

    env.put(
        "/api/admin/compliance/retention",
        json={"anonymize_after_days": 90, "purge_trashed_after_days": 0, "preserve_scorecard_aggregates": False, "enabled": True},
        headers=admin_hdr,
    ).raise_for_status()
    res = env.post("/api/admin/compliance/retention/run", json={"dry_run": False}, headers=admin_hdr)
    assert res.status_code == 200 and res.json()["anonymized_sessions"] == 1

    with store.connection() as db:
        sc = db.execute("SELECT rating, weight, rationale FROM session_scorecards WHERE session_id=?", (s_strict["sid"],)).fetchone()
        assert sc["rating"] == 4 and sc["weight"] == 3 and sc["rationale"] == ""
        hn = db.execute("SELECT category, body FROM session_handoff_notes WHERE session_id=?", (s_strict["sid"],)).fetchone()
        assert hn["category"] == "observation" and hn["body"] == ""

    for _ in range(22):
        env.post("/api/admin/compliance/retention/run", headers=admin_hdr).raise_for_status()
    state = env.get("/api/admin/compliance/retention", headers=admin_hdr).json()
    assert len(state["runs"]) == 20


def test_trashed_session_purge_and_manual_trash_purge_cleanup(env):
    admin_hdr = {"Cookie": f"{access.COOKIE}={_seed_user(email='purge@example.test', role='admin')}"}
    s_old_trash = _create_full_session(env, candidate="Old Trash", consent=True, finished=True, age_days=50)
    s_new_trash = _create_full_session(env, candidate="New Trash", consent=True, finished=True, age_days=50)
    s_anon_then_trash = _create_full_session(env, candidate="Anon Then Trash", consent=True, finished=True, age_days=120)

    # First anonymize s_anon_then_trash (with purge disabled so only anonymization runs).
    env.put(
        "/api/admin/compliance/retention",
        json={"anonymize_after_days": 90, "purge_trashed_after_days": 0, "preserve_scorecard_aggregates": True, "enabled": True},
        headers=admin_hdr,
    ).raise_for_status()
    env.post("/api/admin/compliance/retention/run", json={"dry_run": False}, headers=admin_hdr).raise_for_status()

    # Trash s_old_trash (backdated) and s_new_trash (fresh).
    env.post(f"/api/sessions/{s_old_trash['sid']}/trash").raise_for_status()
    env.post(f"/api/sessions/{s_new_trash['sid']}/trash").raise_for_status()
    old_trashed_at = (datetime.now(timezone.utc) - timedelta(days=45)).isoformat()
    with store.connection(write=True) as db:
        db.execute("UPDATE session_trash SET trashed_at=? WHERE session_id=?", (old_trashed_at, s_old_trash["sid"]))
        db.execute("INSERT INTO session_tags(session_id, tag, created_at) VALUES (?,?,?)", (s_old_trash["sid"], "stale", old_trashed_at))
        db.execute("INSERT INTO note_exports VALUES (?,?,?,?,?,?,?,?)",
                   (str(uuid4()), s_old_trash["sid"], "lever", "r1", "rec@example.test", "draft", "sent", old_trashed_at))

    env.put(
        "/api/admin/compliance/retention",
        json={"anonymize_after_days": 0, "purge_trashed_after_days": 30, "preserve_scorecard_aggregates": True, "enabled": True},
        headers=admin_hdr,
    ).raise_for_status()

    purged = env.post("/api/admin/compliance/retention/run", json={"dry_run": False}, headers=admin_hdr).json()
    assert purged["purged_sessions"] == 1
    assert purged["purged_session_ids"] == [s_old_trash["sid"]]

    with store.connection() as db:
        for table in ("sessions", "session_trash", "session_context", "answers", "answer_review_events",
                      "session_scorecards", "session_handoff_notes", "session_tags", "session_drafts",
                      "transcript_imports", "note_exports", "session_anonymizations"):
            col = "id" if table == "sessions" else "session_id"
            assert db.execute(f"SELECT count(*) FROM {table} WHERE {col}=?", (s_old_trash["sid"],)).fetchone()[0] == 0
        assert db.execute("SELECT count(*) FROM session_trash WHERE session_id=?", (s_new_trash["sid"],)).fetchone()[0] == 1
        assert not db.execute("PRAGMA foreign_key_check").fetchall()

    # Manual trash purge on an already-anonymized session cleans up session_anonymizations too.
    marker = env.post(f"/api/sessions/{s_anon_then_trash['sid']}/trash").json()
    manual = env.post(
        f"/api/trash/{s_anon_then_trash['sid']}/purge",
        json={"operation_version": marker["operation_version"], "confirm_session_id": s_anon_then_trash["sid"]},
    )
    assert manual.status_code == 200 and manual.json() == {"purged": True}
    with store.connection() as db:
        assert db.execute("SELECT count(*) FROM session_anonymizations WHERE session_id=?", (s_anon_then_trash["sid"],)).fetchone()[0] == 0
        assert db.execute("SELECT count(*) FROM sessions WHERE id=?", (s_anon_then_trash["sid"],)).fetchone()[0] == 0
        assert not db.execute("PRAGMA foreign_key_check").fetchall()


def test_execute_retention_job_defensive_without_optional_tables(tmp_path):
    db_file = tmp_path / "minimal.sqlite3"
    with closing(sqlite3.connect(db_file)) as db:
        db.row_factory = sqlite3.Row
        db.executescript(store.SCHEMA)
        retention_policy.migrate(db)
        sid = str(uuid4())
        old = (datetime.now(timezone.utc) - timedelta(days=100)).isoformat()
        db.execute("INSERT INTO sessions VALUES (?,?,?,?,0,?,NULL)", (sid, "Minimal Name", "Eng", "", old))
        db.execute("INSERT INTO session_context(session_id) VALUES (?)", (sid,))
        db.execute("INSERT INTO retention_policies(id, anonymize_after_days, purge_trashed_after_days, preserve_scorecard_aggregates, enabled, updated_by, updated_at) VALUES ('default', 90, 30, 0, 1, 'test', ?) ON CONFLICT(id) DO UPDATE SET preserve_scorecard_aggregates=0", (old,))
        res = retention_policy.execute_retention_job(db, dry_run=False, actor_email="job@example.test")
        assert res["anonymized_sessions"] == 1
        assert db.execute("SELECT candidate FROM sessions WHERE id=?", (sid,)).fetchone()[0] == f"Candidate [Anonymized {sid[:8]}]"
