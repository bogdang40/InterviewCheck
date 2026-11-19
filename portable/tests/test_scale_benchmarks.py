"""Scale benchmark and SQLite query-plan tests on a 5,000-session / 5,000-audit workspace."""
from __future__ import annotations

import json
import os
import statistics
import time
from uuid import UUID, uuid4

from fastapi.testclient import TestClient
import pytest

from api import access, account_db, interview_catalog, store
from api.main import app

SESSIONS = 5000
ANSWERS_PER_SESSION = 6
USERS = 500
AUDIT_ROWS = 5000
AUDIT_ACTIONS = (
    "admin.model.probe",
    "admin.model.create",
    "admin.update_user",
    "auth.login",
    "auth.logout",
)


def _seed_review_workspace() -> None:
    session_ids = [str(UUID(int=i + 1)) for i in range(SESSIONS)]
    with store.connection(write=True) as db:
        db.executemany(
            "INSERT INTO sessions (id,candidate,role,policy,consent,created_at) VALUES (?,?,?,?,?,?)",
            (
                (
                    sid,
                    f"Fixture {i:04}",
                    "Firmware engineer",
                    "Public documentation permitted.",
                    1,
                    f"2026-01-{1 + i % 28:02}T{i % 24:02}:{(i // 24) % 60:02}:00Z",
                )
                for i, sid in enumerate(session_ids)
            ),
        )
        db.executemany(
            "INSERT INTO session_context (session_id,ended_at) VALUES (?,?)",
            ((sid, None if i % 2 else "2026-02-01T00:00:00Z") for i, sid in enumerate(session_ids)),
        )
        db.executemany(
            "INSERT INTO answers (id,session_id,question,answer,refs,result,status) VALUES (?,?,?,?,?,?,?)",
            (
                (
                    str(UUID(int=10000 + i * ANSWERS_PER_SESSION + j)),
                    sid,
                    f"Which clock changes at step {j}?",
                    (
                        "Telemetry synchronization requires an independent oscillator while the primary source is being calibrated."
                    ),
                    "[]",
                    "{}",
                    "match" if i % 3 == j else "no_match",
                )
                for i, sid in enumerate(session_ids)
                for j in range(ANSWERS_PER_SESSION)
            ),
        )


def _seed_access_workspace(admin_id: str) -> None:
    base_ms = 1_760_000_000_000
    extra_users = USERS - 1
    user_ids = [admin_id] + [str(uuid4()) for _ in range(extra_users)]
    with account_db.connection(write=True) as db:
        db.executemany(
            "INSERT INTO users(id,email,password_hash,role,disabled,created_at,updated_at) VALUES (?,?,?,?,?,?,?)",
            (
                (
                    uid,
                    f"scale-user-{idx:04}@example.invalid",
                    account_db.DECOY,
                    "user",
                    0,
                    base_ms + idx * 1000,
                    base_ms + idx * 1000,
                )
                for idx, uid in enumerate(user_ids[1:], start=1)
            ),
        )
        db.executemany(
            "INSERT INTO audit_log(at,actor_user_id,action,target_user_id,details) VALUES (?,?,?,?,?)",
            (
                (
                    base_ms + i * 500,
                    user_ids[i % len(user_ids)],
                    AUDIT_ACTIONS[i % len(AUDIT_ACTIONS)],
                    user_ids[(i + 1) % len(user_ids)],
                    json.dumps({"seq": i, "slug": f"model-{i % 10}"}),
                )
                for i in range(AUDIT_ROWS)
            ),
        )


@pytest.fixture
def scale_workspace(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    for key in (
        "INTERVIEWCHECK_ACCESS_URL",
        "INTERVIEWCHECK_OPERATOR_EMAIL",
        "INTERVIEWCHECK_OPERATOR_ID",
        "INTERVIEWCHECK_PUBLIC_ORIGIN",
        "INTERVIEWCHECK_PRODUCTION",
        "INTERVIEWCHECK_SIGNUP_SECRET",
    ):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("ADMIN_EMAILS", "scale-admin@example.invalid")
    monkeypatch.setenv("ADMIN_BOOTSTRAP_SECRET", "scale-bootstrap-secret")

    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        signup = client.post(
            "/api/integrations/access/signup",
            json={
                "email": "scale-admin@example.invalid",
                "password": "scale-admin-password-123",
                "adminSecret": "scale-bootstrap-secret",
            },
        )
        signup.raise_for_status()
        admin_tok = client.cookies[access.COOKIE]
        me = client.get("/v1/me", headers={"Authorization": f"Bearer {admin_tok}"})
        me.raise_for_status()
        admin_id = me.json()["user"]["id"]

        _seed_review_workspace()
        _seed_access_workspace(admin_id)
        yield client, admin_tok


def _explain(db, sql: str, params: dict | tuple = ()) -> str:
    rows = db.execute(f"EXPLAIN QUERY PLAN {sql}", params).fetchall()
    return " | ".join(str(row[-1]) for row in rows)


def _median_ms(client: TestClient, method: str, path: str, *, runs: int = 5, **kwargs) -> tuple[dict, float]:
    warmup = client.request(method, path, **kwargs)
    warmup.raise_for_status()
    samples: list[float] = []
    last_payload: dict = {}
    for _ in range(runs):
        t0 = time.perf_counter()
        resp = client.request(method, path, **kwargs)
        resp.raise_for_status()
        samples.append((time.perf_counter() - t0) * 1000.0)
        last_payload = resp.json()
    return last_payload, statistics.median(samples)


def test_explain_query_plans_use_scale_indexes(scale_workspace):
    with store.connection() as db:
        feed_plan = _explain(
            db,
            interview_catalog.fast_page_sql("newest", "", has_tag=False),
            {"limit": 25, "offset": 0},
        )
        assert "idx_sessions_created" in feed_plan
        assert "USE TEMP B-TREE FOR ORDER BY" not in feed_plan

    with account_db.connection() as adb:
        assert adb.execute("PRAGMA user_version").fetchone()[0] == 8
        v6_indexes = {
            row[0]
            for row in adb.execute(
                "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%'"
            ).fetchall()
        }
        assert {
            "idx_users_created_id",
            "idx_audit_log_action_id",
            "idx_audit_log_actor_id",
            "idx_audit_log_at_id",
        }.issubset(v6_indexes)

        # Runtime SQL from AuditLogRepository.recent() uses idx_audit_log_at_id.
        recent_audit_plan = _explain(
            adb,
            "SELECT id, at, actor_user_id, action, target_user_id, details FROM audit_log ORDER BY at DESC, id DESC LIMIT ?",
            (50,),
        )
        assert "idx_audit_log_at_id" in recent_audit_plan
        assert "USE TEMP B-TREE FOR ORDER BY" not in recent_audit_plan

        # Runtime SQL from account_admin.audit() and AuditLogRepository.search():
        # cursor pagination walks INTEGER PRIMARY KEY in reverse; action/actor filters use
        # instr(lower(...)) / substr(lower(...)) for case-insensitive substring matching
        # rather than binary equality on idx_audit_log_action_id / idx_audit_log_actor_id,
        # while still avoiding a TEMP B-TREE sort via ORDER BY id DESC.
        audit_cursor_plan = _explain(
            adb,
            "SELECT * FROM audit_log WHERE id < ? ORDER BY id DESC LIMIT ?",
            (1000, 51),
        )
        assert "INTEGER PRIMARY KEY" in audit_cursor_plan
        assert "USE TEMP B-TREE FOR ORDER BY" not in audit_cursor_plan

        for sql, params in (
            (
                "SELECT * FROM audit_log WHERE instr(lower(coalesce(action, '')), ?) > 0 ORDER BY id DESC LIMIT ?",
                ("admin.model.probe", 51),
            ),
            (
                "SELECT * FROM audit_log WHERE substr(lower(action), 1, length(?)) = ? ORDER BY id DESC LIMIT ?",
                ("admin.model.", "admin.model.", 51),
            ),
            (
                "SELECT * FROM audit_log WHERE instr(lower(coalesce(actor_user_id, '')), ?) > 0 ORDER BY id DESC LIMIT ?",
                ("actor-1", 51),
            ),
        ):
            filtered_plan = _explain(adb, sql, params)
            assert "USE TEMP B-TREE FOR ORDER BY" not in filtered_plan

        audit_window_plan = _explain(
            adb,
            "SELECT * FROM audit_log WHERE at >= ? AND at <= ? ORDER BY id DESC LIMIT ?",
            (1_760_000_000_000, 1_760_000_500_000, 51),
        )
        assert "idx_audit_log_at" in audit_window_plan

        # Exact-equality index plans verifying v6 composite indexes remain usable.
        assert "idx_audit_log_action_id" in _explain(
            adb,
            "SELECT * FROM audit_log WHERE action=? ORDER BY id DESC LIMIT ?",
            ("admin.model.probe", 50),
        )
        assert "idx_audit_log_actor_id" in _explain(
            adb,
            "SELECT * FROM audit_log WHERE actor_user_id=? ORDER BY id DESC LIMIT ?",
            ("actor-1", 50),
        )

        # Runtime SQL from account_admin.users() uses idx_users_created_id.
        users_plan = _explain(
            adb,
            (
                "SELECT * FROM users WHERE instr(lower(email),?)>0 AND "
                "(created_at<? OR (created_at=? AND id>?)) ORDER BY created_at DESC,id ASC LIMIT ?"
            ),
            ("", 2**63 - 1, 2**63 - 1, "", 51),
        )
        assert "idx_users_created_id" in users_plan
        assert "USE TEMP B-TREE FOR ORDER BY" not in users_plan


def test_scale_latency_thresholds(scale_workspace):
    client, admin_tok = scale_workspace
    scale = 4.0 if (os.getenv("CI") or os.name == "nt") else 1.0
    with store.connection() as db:
        assert db.execute("SELECT count(*) FROM sessions").fetchone()[0] == SESSIONS
        assert db.execute("SELECT count(*) FROM answers").fetchone()[0] == SESSIONS * ANSWERS_PER_SESSION
    with account_db.connection() as adb:
        assert adb.execute("SELECT count(*) FROM users").fetchone()[0] == USERS
        assert adb.execute("SELECT count(*) FROM audit_log").fetchone()[0] >= AUDIT_ROWS

    feed_p1, feed_p1_ms = _median_ms(client, "GET", "/api/interviews/feed")
    assert feed_p1["total"] == SESSIONS and len(feed_p1["items"]) == 25
    assert feed_p1_ms < 10.0 * scale, f"feed p1 median {feed_p1_ms:.2f} ms >= {10.0 * scale:.0f} ms"

    feed_p100, feed_p100_ms = _median_ms(client, "GET", "/api/interviews/feed?page=100")
    assert feed_p100["page"] == 100 and len(feed_p100["items"]) == 25
    assert feed_p100_ms < 25.0 * scale, f"feed p100 median {feed_p100_ms:.2f} ms >= {25.0 * scale:.0f} ms"

    pending_feed, pending_ms = _median_ms(client, "GET", "/api/interviews/feed?review=pending&sort=pending")
    assert len(pending_feed["items"]) == 25
    assert pending_ms < 35.0 * scale, f"feed pending median {pending_ms:.2f} ms >= {35.0 * scale:.0f} ms"

    overview, overview_ms = _median_ms(client, "GET", "/api/interviews/overview")
    assert overview["total"] == SESSIONS
    assert overview_ms < 25.0 * scale, f"overview median {overview_ms:.2f} ms >= {25.0 * scale:.0f} ms"

    rare, rare_ms = _median_ms(client, "POST", "/api/search", json={"query": "Fixture 4999"})
    assert rare["items"] and rare["items"][0]["label"] == "Fixture 4999"
    assert rare_ms < 15.0 * scale, f"search rare median {rare_ms:.2f} ms >= {15.0 * scale:.0f} ms"

    common, common_ms = _median_ms(client, "POST", "/api/search", json={"query": "oscillator"})
    assert len(common["items"]) == 20 and common["has_more"] is True
    assert common_ms < 60.0 * scale, f"search common median {common_ms:.2f} ms >= {60.0 * scale:.0f} ms"

    audit, audit_ms = _median_ms(
        client,
        "GET",
        "/v1/admin/audit",
        params={"action": "admin.model.probe", "limit": 50},
        headers={"Authorization": f"Bearer {admin_tok}"},
    )
    assert len(audit["entries"]) == 50
    assert all(entry["action"] == "admin.model.probe" for entry in audit["entries"])
    assert audit_ms < 20.0 * scale, f"v1/admin/audit filtered median {audit_ms:.2f} ms >= {20.0 * scale:.0f} ms"
