"""Tests for M25-W2: fleet model health-check timeline, bucketing, filtering, and CSV/JSON export."""
from datetime import datetime, timedelta, timezone
import json
from uuid import uuid4

from fastapi.testclient import TestClient
import pytest

from api import access, account_db, model_registry, rate_limit, secret_box, store
from api.main import app


def _seed_user(*, email: str, role: str) -> str:
    uid, ts = str(uuid4()), account_db.now()
    with account_db.connection(write=True) as db:
        db.execute(
            "INSERT INTO users(id,email,password_hash,role,disabled,created_at,updated_at) VALUES (?,?,?,?,0,?,?)",
            (uid, email, account_db.DECOY, role, ts, ts),
        )
        return account_db.issue(db, uid, "pytest")


def _register_model(*, slug: str, display_name: str, capability: str = "reference", secret: str = "sk-m25-secret-999999") -> str:
    uid = str(uuid4())
    enc = secret_box.encrypt_secret(secret, aad=uid)
    hint = secret_box.mask_key_hint(secret)
    with store.connection(write=True) as db:
        model_registry.create_model(
            db, model_uuid=uid, slug=slug, display_name=display_name, provider="openai",
            capability=capability, model_id="gpt-4o", endpoint=None, api_version=None,
            parameters={"temperature": 0.2}, encrypted_api_key=enc, key_hint=hint,
            enabled=True, is_default=False,
        )
    return uid


def _insert_check(
    db, model_uuid: str, *, source: str, ok: bool, http_status: int,
    latency_ms: int | None, error: str | None, checked_at: datetime,
) -> None:
    db.execute(
        "INSERT INTO model_health_checks(model_id,source,ok,http_status,latency_ms,error,checked_at) VALUES (?,?,?,?,?,?,?)",
        (model_uuid, source, 1 if ok else 0, http_status, latency_ms, error, checked_at.strftime("%Y-%m-%dT%H:%M:%SZ")),
    )


@pytest.fixture
def env(tmp_path, monkeypatch):
    rate_limit.reset_all()
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "m25-timeline-test-key")
    for key in (
        "INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL",
        "INTERVIEWCHECK_OPERATOR_EMAIL", "INTERVIEWCHECK_PUBLIC_ORIGIN",
    ):
        monkeypatch.delenv(key, raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def test_health_timeline_auth_and_validation(env, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("TRIAL_DAYS", "7")

    for path in ("/api/admin/models/health-timeline", "/api/admin/models/health-timeline/export"):
        assert env.get(path).status_code == 401
        forged = {"Cookie": f"{access.COOKIE}=mm_forged_cookie_value_1234567890"}
        assert env.get(path, headers=forged).status_code == 401

    user_cookie = _seed_user(email="reviewer@example.invalid", role="user")
    user_hdr = {"Cookie": f"{access.COOKIE}={user_cookie}"}
    assert env.get("/api/admin/models/health-timeline", headers=user_hdr).status_code == 403
    assert env.get("/api/admin/models/health-timeline/export", headers=user_hdr).status_code == 403

    admin_cookie = _seed_user(email="admin@example.invalid", role="admin")
    env.cookies.set(access.COOKIE, admin_cookie)
    assert env.get("/api/admin/models/health-timeline?hours=0").status_code == 422
    assert env.get("/api/admin/models/health-timeline?hours=721").status_code == 422
    assert env.get("/api/admin/models/health-timeline?bucket_minutes=4").status_code == 422
    assert env.get("/api/admin/models/health-timeline?bucket_minutes=1441").status_code == 422
    assert env.get("/api/admin/models/health-timeline?capability=bogus").status_code == 422
    assert env.get("/api/admin/models/health-timeline?source=cron").status_code == 422
    assert env.get("/api/admin/models/health-timeline?model_id=not-a-uuid").status_code == 422
    assert env.get("/api/admin/models/health-timeline?limit=201").status_code == 422
    assert env.get("/api/admin/models/health-timeline/export?format=xml").status_code == 422
    assert env.get("/api/admin/models/health-timeline/export?limit=2001").status_code == 422


def test_health_timeline_bucketing_percentiles_and_filters(env, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("TRIAL_DAYS", "7")
    admin_cookie = _seed_user(email="admin@example.invalid", role="admin")
    env.cookies.set(access.COOKIE, admin_cookie)

    ref_id = _register_model(slug="ref-primary", display_name="Ref Primary", capability="reference")
    judge_id = _register_model(slug="judge-alpha", display_name="Judge Alpha", capability="judge")

    now = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    b1 = now - timedelta(hours=2)
    b2 = now - timedelta(hours=1)
    stale = now - timedelta(hours=40)

    with store.connection(write=True) as db:
        for i, lat in enumerate((100, 200, 300, 400)):
            _insert_check(db, ref_id, source="probe", ok=True, http_status=200, latency_ms=lat, error=None, checked_at=b1 + timedelta(minutes=i))
        _insert_check(db, ref_id, source="live", ok=False, http_status=503, latency_ms=500, error="Upstream 503", checked_at=b1 + timedelta(minutes=10))
        for i, lat in enumerate((600, 700, 800, 900)):
            _insert_check(db, judge_id, source="live", ok=True, http_status=200, latency_ms=lat, error=None, checked_at=b2 + timedelta(minutes=i))
        _insert_check(db, judge_id, source="probe", ok=False, http_status=502, latency_ms=1000, error="Bad gateway", checked_at=b2 + timedelta(minutes=10))
        _insert_check(db, ref_id, source="probe", ok=False, http_status=500, latency_ms=1200, error="Stale error", checked_at=stale)

    res = env.get("/api/admin/models/health-timeline?hours=24&bucket_minutes=60")
    assert res.status_code == 200
    assert res.headers.get("cache-control") == "no-store"
    body = res.json()
    assert body["window"]["hours"] == 24 and body["window"]["bucket_minutes"] == 60
    assert body["summary"] == {
        "total_checks": 10,
        "ok_count": 8,
        "error_count": 2,
        "uptime_pct": 80.0,
        "avg_latency_ms": 550,
        "p50_latency_ms": 500,
        "p95_latency_ms": 1000,
        "p99_latency_ms": 1000,
        "models_with_errors": 2,
    }
    assert len(body["buckets"]) == 2
    assert body["buckets"][0]["bucket_start"] < body["buckets"][1]["bucket_start"]
    assert body["buckets"][0]["total_checks"] == 5 and body["buckets"][0]["ok_count"] == 4
    assert body["buckets"][0]["uptime_pct"] == 80.0 and body["buckets"][0]["p95_latency_ms"] == 500
    assert body["buckets"][1]["total_checks"] == 5 and body["buckets"][1]["error_count"] == 1
    assert body["buckets"][1]["p95_latency_ms"] == 1000
    assert len(body["recent_events"]) == 10
    assert body["recent_events"][0]["checked_at"] >= body["recent_events"][-1]["checked_at"]

    f_5m = env.get("/api/admin/models/health-timeline?hours=24&bucket_minutes=5").json()
    assert len(f_5m["buckets"]) == 4

    f_model = env.get(f"/api/admin/models/health-timeline?hours=24&model_id={ref_id}").json()
    assert f_model["summary"]["total_checks"] == 5 and f_model["summary"]["models_with_errors"] == 1
    assert all(ev["model_id"] == ref_id for ev in f_model["recent_events"])

    f_cap = env.get("/api/admin/models/health-timeline?hours=24&capability=judge").json()
    assert f_cap["summary"]["total_checks"] == 5 and all(ev["capability"] == "judge" for ev in f_cap["recent_events"])

    f_src = env.get("/api/admin/models/health-timeline?hours=24&source=probe&limit=2").json()
    assert f_src["summary"]["total_checks"] == 5 and len(f_src["recent_events"]) == 2
    assert all(ev["source"] == "probe" for ev in f_src["recent_events"])

    f_wide = env.get("/api/admin/models/health-timeline?hours=72").json()
    assert f_wide["summary"]["total_checks"] == 11


def test_health_timeline_export_csv_json_and_secret_scrubbing(env, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("TRIAL_DAYS", "7")
    admin_cookie = _seed_user(email="admin@example.invalid", role="admin")
    env.cookies.set(access.COOKIE, admin_cookie)

    secret_val = "sk-live-TopSecretValue123456"
    mid = _register_model(slug="csv-inj", display_name="=cmd|'/C calc'!A0", capability="reference", secret=secret_val)
    now = datetime.now(timezone.utc)
    with store.connection(write=True) as db:
        _insert_check(
            db, mid, source="probe", ok=False, http_status=500, latency_ms=145,
            error="+1@SUM(A1:A2) failed sk-proj-AbCdEfGhIjKlMnOpQrStUv /Users/alice/key.pem Bearer tok_secret_987",
            checked_at=now - timedelta(minutes=5),
        )
        _insert_check(
            db, mid, source="live", ok=False, http_status=429, latency_ms=None,
            error="@SUM(1,2) rate limited", checked_at=now - timedelta(minutes=2),
        )

    tl = env.get("/api/admin/models/health-timeline?hours=24")
    assert tl.status_code == 200
    tl_text = tl.text
    for forbidden in (secret_val, "sk-proj-", "/Users/alice", "tok_secret_987", "encrypted_api_key", "config_json"):
        assert forbidden not in tl_text

    csv_res = env.get("/api/admin/models/health-timeline/export?format=csv&hours=24")
    assert csv_res.status_code == 200
    assert csv_res.headers.get("cache-control") == "no-store"
    assert 'filename="model-health-timeline.csv"' in csv_res.headers.get("content-disposition", "")
    assert csv_res.content.startswith(b"\xef\xbb\xbf")
    csv_text = csv_res.content.decode("utf-8-sig")
    assert "'=cmd|'/C calc'!A0" in csv_text
    assert "'+1@SUM(A1:A2)" in csv_text
    assert "'@SUM(1,2) rate limited" in csv_text
    for forbidden in (secret_val, "sk-proj-", "/Users/alice", "tok_secret_987"):
        assert forbidden not in csv_text

    json_res = env.get("/api/admin/models/health-timeline/export?format=json&hours=24")
    assert json_res.status_code == 200
    assert json_res.headers.get("cache-control") == "no-store"
    assert 'filename="model-health-timeline.json"' in json_res.headers.get("content-disposition", "")
    doc = json.loads(json_res.text)
    assert {"exported_at", "filters", "window", "summary", "buckets", "events"} <= set(doc.keys())
    assert len(doc["events"]) == 2
    for forbidden in (secret_val, "sk-proj-", "/Users/alice", "tok_secret_987"):
        assert forbidden not in json_res.text


def test_health_timeline_defensive_when_tables_missing(env, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("TRIAL_DAYS", "7")
    admin_cookie = _seed_user(email="admin@example.invalid", role="admin")
    env.cookies.set(access.COOKIE, admin_cookie)

    with store.connection(write=True) as db:
        db.execute("DROP TABLE IF EXISTS model_health_checks")
        db.execute("DROP TABLE IF EXISTS connected_models")

    tl = env.get("/api/admin/models/health-timeline")
    assert tl.status_code == 200
    body = tl.json()
    assert body["summary"]["total_checks"] == 0 and body["summary"]["uptime_pct"] is None
    assert body["buckets"] == [] and body["recent_events"] == []

    csv_res = env.get("/api/admin/models/health-timeline/export?format=csv")
    assert csv_res.status_code == 200 and csv_res.content.startswith(b"\xef\xbb\xbf")
    json_res = env.get("/api/admin/models/health-timeline/export?format=json")
    assert json_res.status_code == 200 and json_res.json()["events"] == []
