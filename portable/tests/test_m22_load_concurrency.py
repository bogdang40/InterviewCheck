"""Load, WAL concurrency, latency, and audit hash chain tests across M11-M21."""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor, as_completed
import math
import os
import random
import socket
import sqlite3
import threading
import time
from uuid import UUID, uuid4

import httpx
import pytest
import uvicorn

from api import access, account_db, bulk_operations, rate_limit, retention_policy, session_scorecard, store
from api.main import app
from api.models import RoleInput, RubricCriterion

SESSIONS = 2100
ANSWERS_PER_SESSION = 3
TAGS = ("senior", "backend", "frontend", "platform", "referral", "onsite", "followup", "priority")
ROLES = ("Firmware Engineer", "Backend Systems", "Product Security", "ML Infrastructure")


def _p95_ms(samples: list[float]) -> float:
    ordered = sorted(samples)
    return ordered[max(0, math.ceil(0.95 * len(ordered)) - 1)]


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _seed_workspace(admin_id: str) -> dict[str, object]:
    role_ids: list[str] = []
    criterion_ids: list[str] = []
    with store.connection(write=True) as db:
        bulk_operations.ensure_table(db)
        session_scorecard.migrate(db)
        retention_policy.migrate(db)
        for idx, name in enumerate(ROLES):
            cid = str(uuid4())
            criterion_ids.append(cid)
            role = store.create_role(
                db,
                RoleInput(
                    name=name,
                    description=f"Scale role {idx}",
                    questions=[f"Explain architecture tradeoff {idx}.", f"Describe debugging approach {idx}."],
                    rubric=[RubricCriterion(id=cid, criterion=f"Core depth {idx}", weight=3)],
                ),
            )
            role_ids.append(role["id"])

        session_ids = [str(UUID(int=i + 1)) for i in range(SESSIONS)]
        db.executemany(
            "INSERT INTO sessions(id,candidate,role,policy,consent,created_at) VALUES (?,?,?,?,?,?)",
            (
                (
                    sid, f"Load Candidate {i:04}", ROLES[i % len(ROLES)], "Public docs permitted.",
                    0 if i % 10 == 0 else 1, f"2026-01-{1 + (i % 28):02}T{i % 24:02}:{(i // 24) % 60:02}:00Z",
                )
                for i, sid in enumerate(session_ids)
            ),
        )
        db.executemany(
            "INSERT INTO session_context(session_id,role_id,questions,ended_at) VALUES (?,?,?,?)",
            (
                (sid, role_ids[i % len(role_ids)], '["Explain architecture tradeoff."]', "2026-02-01T12:00:00Z" if i % 3 == 0 else None)
                for i, sid in enumerate(session_ids)
            ),
        )
        db.executemany(
            "INSERT INTO answers(id,session_id,question,answer,refs,result,status,disposition) VALUES (?,?,?,?,?,?,?,?)",
            (
                (
                    str(UUID(int=200_000 + i * ANSWERS_PER_SESSION + j)), sid, f"Question {j}",
                    "WAL mode separates concurrent readers from serialized writers using append frames.",
                    "[]", "{}", "match" if j == 0 else "no_match",
                    ("explained" if i % 3 == 0 else ("unresolved" if i % 5 == 0 else "pending")) if j == 0 else "pending",
                )
                for i, sid in enumerate(session_ids)
                for j in range(ANSWERS_PER_SESSION)
            ),
        )
        db.executemany(
            "INSERT INTO session_tags(session_id,tag,created_at) VALUES (?,?,?)",
            ((sid, TAGS[(i + off) % len(TAGS)], "2026-02-02T00:00:00Z") for i, sid in enumerate(session_ids) for off in (0, 3)),
        )
        db.executemany(
            "INSERT INTO session_scorecards(session_id,criterion_id,criterion_label,weight,rating,rationale,updated_by,updated_at)"
            " VALUES (?,?,?,?,?,?,?,?)",
            (
                (
                    sid, criterion_ids[i % len(role_ids)], f"Core depth {i % len(role_ids)}", 3,
                    (i % 5) + 1, "Load fixture scorecard.", "load-admin@example.invalid", "2026-02-02T01:00:00Z",
                )
                for i, sid in enumerate(session_ids[:1000])
            ),
        )

    with account_db.connection(write=True) as adb:
        base_ms = 1_760_000_000_000
        extra_users = [str(uuid4()) for _ in range(150)]
        adb.executemany(
            "INSERT INTO users(id,email,password_hash,role,disabled,created_at,updated_at) VALUES (?,?,?,?,?,?,?)",
            ((uid, f"load-user-{i:03}@example.invalid", account_db.DECOY, "user", 0, base_ms + i, base_ms + i) for i, uid in enumerate(extra_users)),
        )
        for i in range(300):
            account_db.audit(adb, "load.seed.audit", extra_users[i % len(extra_users)], admin_id, {"seq": i}, at=base_ms + i * 100)
    return {"role_ids": role_ids, "session_ids": session_ids, "criterion_ids": criterion_ids}


@pytest.fixture
def load_env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("ADMIN_EMAILS", "load-admin@example.invalid")
    monkeypatch.setenv("ADMIN_BOOTSTRAP_SECRET", "load-bootstrap-secret")
    monkeypatch.setenv("INTERVIEWCHECK_METRICS_TOKEN", "load-metrics-token")
    for key in (
        "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_OPERATOR_EMAIL", "INTERVIEWCHECK_OPERATOR_ID",
        "INTERVIEWCHECK_PUBLIC_ORIGIN", "INTERVIEWCHECK_PRODUCTION", "INTERVIEWCHECK_SIGNUP_SECRET",
    ):
        monkeypatch.delenv(key, raising=False)
    rate_limit.reset_all()

    port = _free_port()
    base_url = f"http://127.0.0.1:{port}"
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="error", access_log=False))
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    deadline = time.monotonic() + 10.0
    while not server.started and time.monotonic() < deadline:
        time.sleep(0.02)
    assert server.started, "Timed out starting uvicorn server"

    try:
        with httpx.Client(base_url=base_url, headers={"X-InterviewCheck": "1"}, timeout=10.0) as client:
            signup = client.post(
                "/api/integrations/access/signup",
                json={"email": "load-admin@example.invalid", "password": "load-admin-password-123", "adminSecret": "load-bootstrap-secret"},
            )
            signup.raise_for_status()
            admin_tok = client.cookies[access.COOKIE]
            me = client.get("/v1/me", headers={"Authorization": f"Bearer {admin_tok}"})
            me.raise_for_status()
            admin_id = me.json()["user"]["id"]
            seeded = _seed_workspace(admin_id)
            assert client.get("/api/interviews/feed").status_code == 200
            assert client.get("/api/analytics/cohorts").status_code == 200
            yield {"base_url": base_url, "admin_id": admin_id, "admin_tok": admin_tok, **seeded}
    finally:
        server.should_exit = True
        thread.join(timeout=5.0)


def test_concurrent_wal_load_latency_and_audit_chain(load_env):
    base_url: str = load_env["base_url"]
    role_ids: list[str] = load_env["role_ids"]
    session_ids: list[str] = load_env["session_ids"]
    criterion_ids: list[str] = load_env["criterion_ids"]
    admin_id: str = load_env["admin_id"]
    admin_tok: str = load_env["admin_tok"]

    with account_db.connection() as adb:
        assert adb.execute("PRAGMA user_version").fetchone()[0] == 8
        initial_chain = account_db.verify_audit_chain(adb)
        assert initial_chain["ok"] is True
        initial_verified = int(initial_chain["verifiedCount"])

    tls = threading.local()
    clients_lock = threading.Lock()
    created_clients: list[httpx.Client] = []

    def thread_client() -> httpx.Client:
        client = getattr(tls, "client", None)
        if client is None:
            client = httpx.Client(base_url=base_url, headers={"X-InterviewCheck": "1"}, cookies={access.COOKIE: admin_tok}, timeout=10.0)
            client.get("/api/health").raise_for_status()
            tls.client = client
            with clients_lock:
                created_clients.append(client)
        return client

    results_lock = threading.Lock()
    catalog_ms: list[float] = []
    cohort_ms: list[float] = []
    op_errors: list[str] = []
    other_errors: list[str] = []
    metrics_bodies: list[str] = []
    audit_appends = 0
    retention_dry_runs = 0

    def run_task(kind: str, idx: int) -> None:
        nonlocal audit_appends, retention_dry_runs
        try:
            client = thread_client()
            if kind == "catalog":
                rid, tag = role_ids[idx % len(role_ids)], TAGS[idx % len(TAGS)]
                url = "/api/interviews/feed?page=1&page_size=25" if idx % 3 == 0 else (
                    f"/api/interviews/feed?role_id={rid}&page_size=25" if idx % 3 == 1 else f"/api/interviews/feed?tag={tag}&status=finished"
                )
                t0 = time.perf_counter()
                resp = client.get(url)
                elapsed = (time.perf_counter() - t0) * 1000.0
                assert resp.status_code == 200 and resp.json()["total"] == SESSIONS
                assert client.get("/api/interviews/tags").status_code == 200
                with results_lock:
                    catalog_ms.append(elapsed)
            elif kind == "cohort":
                rid, tag = role_ids[idx % len(role_ids)], TAGS[idx % len(TAGS)]
                url = "/api/analytics/cohorts" if idx % 8 == 0 else (
                    f"/api/analytics/cohorts?role_id={rid}&lifecycle=finished" if idx % 2 == 1 else f"/api/analytics/cohorts?tag={tag}"
                )
                t0 = time.perf_counter()
                resp = client.get(url)
                elapsed = (time.perf_counter() - t0) * 1000.0
                assert resp.status_code == 200 and resp.json()["summary"]["session_count"] >= 150
                with results_lock:
                    cohort_ms.append(elapsed)
            elif kind == "scorecard":
                sid, r_idx = session_ids[1100 + idx], (1100 + idx) % len(role_ids)
                put_resp = client.put(
                    f"/api/sessions/{sid}/scorecard",
                    json={"items": [{"criterion_id": criterion_ids[r_idx], "criterion_label": f"Core depth {r_idx}", "weight": 3, "rating": (idx % 5) + 1, "rationale": f"Concurrent rating {idx}"}]},
                )
                assert put_resp.status_code == 200
                get_resp = client.get(f"/api/sessions/{sid}/scorecard")
                assert get_resp.status_code == 200 and get_resp.json()["weighted_score_pct"] is not None
            elif kind == "compare":
                base = (idx * 7) % (SESSIONS - 5)
                resp = client.post("/api/interviews/compare", json={"session_ids": session_ids[base : base + 3]})
                assert resp.status_code == 200 and len(resp.json()["sessions"]) == 3
            elif kind == "retention":
                resp = client.post("/api/admin/compliance/retention/run", json={"dry_run": True})
                assert resp.status_code == 200 and resp.json()["dry_run"] is True and resp.json()["anonymized_sessions"] >= 0
                with results_lock:
                    retention_dry_runs += 1
            elif kind == "metrics":
                headers = {"Authorization": "Bearer load-metrics-token"} if idx % 2 == 0 else {}
                resp = client.get("/api/admin/metrics", headers=headers)
                assert resp.status_code == 200 and "ic_sessions_total" in resp.text and "ic_http_requests_total" in resp.text
                with results_lock:
                    metrics_bodies.append(resp.text)
            elif kind == "audit":
                with account_db.connection(write=True) as adb:
                    account_db.audit(adb, "load.concurrent.event", admin_id, admin_id, {"worker_idx": idx})
                with results_lock:
                    audit_appends += 1
        except sqlite3.OperationalError as exc:
            with results_lock:
                op_errors.append(f"{kind}-{idx}: {exc}")
        except Exception as exc:
            with results_lock:
                other_errors.append(f"{kind}-{idx}: {type(exc).__name__}: {exc}")

    tasks = (
        [("catalog", i) for i in range(40)]
        + [("cohort", i) for i in range(40)]
        + [("scorecard", i) for i in range(20)]
        + [("compare", i) for i in range(16)]
        + [("retention", i) for i in range(6)]
        + [("metrics", i) for i in range(16)]
        + [("audit", i) for i in range(30)]
    )
    random.Random(42).shuffle(tasks)

    try:
        with ThreadPoolExecutor(max_workers=4) as pool:
            for fut in as_completed([pool.submit(run_task, kind, idx) for kind, idx in tasks]):
                fut.result()
    finally:
        for c in created_clients:
            c.close()

    assert op_errors == [], f"SQLite OperationalError lock failures: {op_errors}"
    assert other_errors == [], f"Unexpected concurrent errors: {other_errors}"
    assert len(catalog_ms) == 40 and len(cohort_ms) == 40
    scale = 4.0 if (os.getenv("CI") or os.name == "nt") else 1.0
    assert _p95_ms(catalog_ms) < 250.0 * scale, f"Catalog p95 too high: {_p95_ms(catalog_ms):.1f}ms"
    assert _p95_ms(cohort_ms) < 250.0 * scale, f"Cohort p95 too high: {_p95_ms(cohort_ms):.1f}ms"
    assert retention_dry_runs == 6 and len(metrics_bodies) == 16 and audit_appends == 30

    with store.connection() as db:
        assert db.execute("SELECT COUNT(*) FROM session_anonymizations").fetchone()[0] == 0
        assert db.execute("SELECT COUNT(*) FROM retention_runs WHERE dry_run=1").fetchone()[0] == 6
        assert db.execute("SELECT COUNT(*) FROM sessions").fetchone()[0] == SESSIONS

    with account_db.connection() as adb:
        assert adb.execute("PRAGMA user_version").fetchone()[0] == 8
        final_chain = account_db.verify_audit_chain(adb)
        assert final_chain["ok"] is True
        assert final_chain["firstBrokenId"] is None
        assert final_chain["verifiedCount"] == initial_verified + audit_appends
