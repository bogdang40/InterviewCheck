"""Tests for M16-W1 OpenMetrics / JSON observability and MetricsMiddleware."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from uuid import uuid4

from fastapi import FastAPI
from fastapi.testclient import TestClient
import pytest

from api import account_db, main, model_budgets, model_registry, model_telemetry, rate_limit, store
from api.local_boundary import LocalBoundary
from api.metrics_export import MetricsMiddleware, MetricsRegistry, router as metrics_router
from api.security_headers import SecurityHeadersMiddleware


def _build_test_app(registry: MetricsRegistry) -> FastAPI:
    test_app = FastAPI(title="MetricsTest", lifespan=main.app.router.lifespan_context)
    test_app.state.metrics_registry = registry
    test_app.add_middleware(LocalBoundary)
    test_app.add_middleware(SecurityHeadersMiddleware)
    test_app.add_middleware(MetricsMiddleware, registry=registry)
    test_app.include_router(metrics_router)
    test_app.include_router(main.workspace)
    test_app.include_router(main.model_admin.router)

    @test_app.get("/api/health")
    def health():
        return {"ok": True}

    return test_app


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "fixture-metrics-secret")
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_OPERATOR_EMAIL", "INTERVIEWCHECK_METRICS_TOKEN"):
        monkeypatch.delenv(key, raising=False)
    reg = MetricsRegistry()
    test_app = _build_test_app(reg)
    with TestClient(test_app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        yield client, reg, tmp_path


def _seed_user(email: str, role: str) -> str:
    with account_db.connection(write=True) as db:
        ts = account_db.now()
        uid = str(uuid4())
        db.execute(
            "INSERT INTO users(id,email,password_hash,role,disabled,created_at,updated_at) VALUES (?,?,?,?,0,?,?)",
            (uid, email, account_db.DECOY, role, ts, ts),
        )
        return account_db.issue(db, uid, "pytest")


def test_metrics_auth_gates_and_timing_safe_token(env, monkeypatch):
    client, _, _ = env
    assert client.get("/api/admin/metrics").status_code == 401

    member_tok = _seed_user("member-pii@example.invalid", "user")
    client.cookies.set("ic_access", member_tok)
    assert client.get("/api/admin/metrics").status_code == 403

    monkeypatch.setenv("INTERVIEWCHECK_METRICS_TOKEN", "metrics-bearer-secret-42")
    assert client.get("/api/admin/metrics", headers={"Authorization": "Bearer wrong-token"}).status_code == 401

    bearer_res = client.get("/api/admin/metrics?format=json", headers={"Authorization": "Bearer metrics-bearer-secret-42"})
    assert bearer_res.status_code == 200
    assert bearer_res.headers["cache-control"] == "no-store"

    admin_tok = _seed_user("admin-pii@example.invalid", "admin")
    client.cookies.set("ic_access", admin_tok)
    admin_res = client.get("/api/admin/metrics?format=prometheus")
    assert admin_res.status_code == 200
    assert admin_res.headers["content-type"].startswith("text/plain; version=0.0.4")
    assert admin_res.headers["cache-control"] == "no-store"
    assert client.get("/api/admin/metrics?format=xml").status_code == 422


def test_middleware_cardinality_bounding_and_thread_safety(env):
    client, reg, _ = env
    admin_tok = _seed_user("card-admin@example.invalid", "admin")
    client.cookies.set("ic_access", admin_tok)

    sids = [str(uuid4()) for _ in range(5)]
    for sid in sids:
        assert client.get(f"/api/sessions/{sid}").status_code == 404
    assert client.get("/api/sessions/alice@example.com").status_code == 422
    assert client.get("/nonexistent/raw-path-123").status_code == 404

    payload = client.get("/api/admin/metrics?format=json").json()
    routes = {item["route"] for item in payload["http"]["requests"]}
    assert "/api/sessions/{sid}" in routes
    assert "<unmatched>" in routes
    for sid in sids:
        assert sid not in str(routes)
    assert "alice@example.com" not in str(routes)
    assert "/nonexistent/raw-path-123" not in str(routes)

    # HTTP 429 through MetricsMiddleware increments ic_rate_limit_rejections_total
    for _ in range(16):
        client.post(f"/api/admin/models/{sids[0]}/probe")
    after_429 = client.get("/api/admin/metrics?format=json").json()
    assert after_429["http"]["rate_limit_rejections_total"] >= 1
    rate_limit.reset_all()

    # Overflow cardinality bounding and concurrent thread safety on MetricsRegistry
    local_reg = MetricsRegistry()
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(lambda idx: local_reg.observe("GET", "/api/concurrent", 200, float(idx)), range(40)))
    for i in range(300):
        local_reg.observe("GET", f"/r/{i}", 200, 12.5)
    local_reg.observe("POST", "/api/rate", 429, 4.0)
    local_reg.observe("WEIRD", "/api/rate", 200, 1.0)
    snap = local_reg.snapshot_http()
    assert any(item["route"] == "<other>" for item in snap["requests"])
    assert any(item["method"] == "OTHER" for item in snap["requests"])
    assert snap["rate_limit_rejections_total"] == 1
    conc = [item for item in snap["requests"] if item["route"] == "/api/concurrent"]
    assert conc[0]["count"] == 40

    # Also verify MetricsMiddleware works directly wrapping main.app without modifying main.py
    main_reg = MetricsRegistry()
    with TestClient(MetricsMiddleware(main.app, registry=main_reg), base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as mc:
        assert mc.get(f"/api/sessions/{sids[0]}").status_code == 404
    assert {item["route"] for item in main_reg.snapshot_http()["requests"]} == {"/api/sessions/{sid}"}


def test_prometheus_and_json_gauges_without_and_with_usage_table(env, monkeypatch):
    client, _, tmp_path = env
    monkeypatch.setenv("INTERVIEWCHECK_METRICS_TOKEN", "metrics-bearer-secret-42")
    admin_tok = _seed_user("pii-admin@secret.invalid", "admin")
    client.cookies.set("ic_access", admin_tok)

    # Seed active, finished, archived, and trashed sessions
    s_active = client.post("/api/sessions", json={"candidate": "Candidate SecretName", "role": "Staff", "policy": "P", "consent": True}).json()["id"]
    s_fin = client.post("/api/sessions", json={"candidate": "Bob", "role": "Staff", "policy": "P", "consent": True}).json()["id"]
    s_arch = client.post("/api/sessions", json={"candidate": "Cara", "role": "Staff", "policy": "P", "consent": True}).json()["id"]
    s_trash = client.post("/api/sessions", json={"candidate": "Dan", "role": "Staff", "policy": "P", "consent": True}).json()["id"]
    with store.connection(write=True) as db:
        db.execute("UPDATE sessions SET consent=0 WHERE id=?", (s_arch,))
        db.execute("UPDATE session_context SET ended_at=? WHERE session_id=?", ("2026-11-19T00:00:00Z", s_fin))
        db.execute("INSERT INTO session_trash(session_id,trashed_at,operation_version) VALUES (?,?,?)", (s_trash, "2026-11-19T00:00:00Z", "1"))
        mid = str(uuid4())
        model_registry.create_model(
            db,
            model_uuid=mid,
            slug="judge-primary",
            display_name="Judge Model",
            provider="openai_compatible",
            capability="judge",
            model_id="gpt-4o",
            endpoint="https://private-llm.internal/v1",
            api_version=None,
            parameters={"fallback_priority": 10},
            encrypted_api_key="enc:v1:sk-secret-api-key-9999",
            key_hint="...9999",
            enabled=True,
            is_default=True,
        )
        model_telemetry.record_check(db, mid, source="probe", ok=True, http_status=200, latency_ms=42, error=None, checked_at="2026-11-19T00:00:00Z")

    # Defensive sqlite_master check when model_usage_daily is absent
    with store.connection(write=True) as db:
        db.execute("DROP TABLE IF EXISTS model_usage_daily")
    pre_m11 = client.get("/api/admin/metrics?format=json").json()
    assert pre_m11["model_daily_tokens"] == []
    assert pre_m11["sqlite_page_count"]["review"] > 0
    assert pre_m11["sqlite_page_count"]["access"] > 0
    assert pre_m11["sessions"] == {"active": 1, "finished": 1, "archived": 1, "trashed": 1}
    assert pre_m11["connected_models"] == [{"capability": "judge", "status": "unverified", "count": 1}]
    assert pre_m11["model_checks"] == [{"capability": "judge", "ok": "true", "count": 1}]

    # Restore M11 model_usage_daily schema and record usage
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    with store.connection(write=True) as db:
        model_budgets.migrate(db)
        model_budgets.record_usage(db, mid, input_tokens=120, output_tokens=80, ok=True, config=None, usage_date=today)

    prom = client.get("/api/admin/metrics?format=prometheus").text
    for expected in (
        "ic_http_requests_total{",
        "ic_http_request_duration_ms_bucket{",
        "ic_rate_limit_rejections_total ",
        'ic_sqlite_wal_bytes{db="review"}',
        'ic_sqlite_wal_bytes{db="access"}',
        'ic_sqlite_page_count{db="review"}',
        'ic_sqlite_page_count{db="access"}',
        'ic_connected_models_total{capability="judge",status="unverified"} 1',
        'ic_model_checks_total{capability="judge",ok="true"} 1',
        'ic_model_daily_tokens_total{capability="judge"} 200',
        'ic_sessions_total{lifecycle="active"} 1',
        'ic_sessions_total{lifecycle="trashed"} 1',
    ):
        assert expected in prom

    # Zero PII or secret leakage in either format
    json_text = client.get("/api/admin/metrics?format=json").text
    for combined in (prom, json_text):
        for forbidden in (
            "pii-admin@secret.invalid",
            "Candidate SecretName",
            "sk-secret-api-key-9999",
            "private-llm.internal",
            "metrics-bearer-secret-42",
            str(tmp_path),
            s_active,
            s_arch,
            mid,
        ):
            assert forbidden not in combined
    rate_limit.reset_all()
