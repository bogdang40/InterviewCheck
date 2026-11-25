"""Admin Usage tab: privacy of public visit counts and the admin usage summary."""
from fastapi.testclient import TestClient
import pytest

from api import rate_limit, store, usage_events
from api.main import app

BROWSER = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36"
PHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1"


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    for key in ("INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_OPERATOR_EMAIL", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    rate_limit.reset_all()
    store.initialize(store.db_path())
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def _rows():
    with store.connection() as db:
        return [dict(r) for r in db.execute("SELECT day, kind, visitor, count FROM usage_daily ORDER BY kind")]


def test_signed_out_visits_are_counted_once_per_visitor_without_storing_the_address(env):
    for _ in range(3):
        assert env.post("/api/usage/visit", json={"page": "home"}, headers={"User-Agent": BROWSER}).status_code == 204
    assert env.post("/api/usage/visit", json={"page": "sample"}, headers={"User-Agent": BROWSER}).status_code == 204
    assert env.post("/api/usage/visit", json={"page": "home"}, headers={"User-Agent": PHONE}).status_code == 204
    # Link previews, crawlers and scripted browsers are not visitors.
    for agent in ("Twitterbot/1.0", "curl/8.4.0", "Mozilla/5.0 HeadlessChrome/131.0", ""):
        assert env.post("/api/usage/visit", json={"page": "home"}, headers={"User-Agent": agent}).status_code == 204
    assert env.post("/api/usage/visit", json={"page": "admin"}, headers={"User-Agent": BROWSER}).status_code == 422
    assert env.post("/api/usage/visit", json={"page": "home", "extra": 1}, headers={"User-Agent": BROWSER}).status_code == 422

    rows = _rows()
    home = [r for r in rows if r["kind"] == "visit:home"]
    assert sorted(r["count"] for r in home) == [1, 3]
    assert all(len(r["visitor"]) == 16 and "127.0.0.1" not in r["visitor"] for r in rows)
    with store.connection() as db:
        counts = usage_events.daily_counts(db, usage_events.today())[usage_events.today()]
    assert counts["visit:home"] == 2 and counts["visit:home:views"] == 4
    assert counts["visitors"] == 2  # the desktop visitor saw two pages but is one person


def test_salt_is_replaced_each_day_so_visitors_cannot_be_followed(env, monkeypatch):
    monkeypatch.setattr(usage_events, "today", lambda: "2026-11-01")
    env.post("/api/usage/visit", json={"page": "home"}, headers={"User-Agent": BROWSER})
    monkeypatch.setattr(usage_events, "today", lambda: "2026-11-02")
    env.post("/api/usage/visit", json={"page": "home"}, headers={"User-Agent": BROWSER})
    rows = _rows()
    assert len(rows) == 2 and rows[0]["visitor"] != rows[1]["visitor"]
    with store.connection() as db:
        assert [r[0] for r in db.execute("SELECT day FROM usage_salt")] == ["2026-11-02"]


def test_page_views_per_visitor_are_capped(env):
    rate_limit.SITE_VISIT.reset()
    with store.connection(write=True) as db:
        for _ in range(usage_events.VIEW_CAP + 5):
            usage_events.record_visit(db, "home", "198.51.100.7", BROWSER)
    assert _rows()[0]["count"] == usage_events.VIEW_CAP


def test_visit_endpoint_is_rate_limited(env):
    codes = [env.post("/api/usage/visit", json={"page": "home"}, headers={"User-Agent": BROWSER}).status_code for _ in range(35)]
    assert codes.count(204) == 30 and codes[-1] == 429


def test_usage_summary_requires_an_admin(env, monkeypatch):
    assert env.get("/api/admin/usage").status_code in (401, 403)
    monkeypatch.setenv("ADMIN_BOOTSTRAP_SECRET", "bootstrap-fixture-secret")
    member = env.post("/api/integrations/access/signup", json={"email": "member@example.invalid", "password": "strong-password-1"})
    assert member.status_code == 200 and not member.json().get("admin")
    assert env.get("/api/admin/usage").status_code == 403


def test_admin_sees_visits_sign_ins_people_interviews_and_answers(env, monkeypatch):
    monkeypatch.setenv("ADMIN_EMAILS", "owner@example.invalid")
    monkeypatch.setenv("ADMIN_BOOTSTRAP_SECRET", "bootstrap-fixture-secret")
    monkeypatch.setenv("INTERVIEWCHECK_OPERATOR_EMAIL", "owner@example.invalid")
    env.post("/api/usage/visit", json={"page": "home"}, headers={"User-Agent": BROWSER})
    env.post("/api/usage/visit", json={"page": "signin"}, headers={"User-Agent": BROWSER})
    signup = env.post("/api/integrations/access/signup",
                      json={"email": "owner@example.invalid", "password": "strong-password-1", "adminSecret": "bootstrap-fixture-secret"})
    assert signup.status_code == 200 and signup.json().get("admin") is True
    session = env.post("/api/sessions", json={"candidate": "Usage Candidate", "role": "Backend engineer",
                                              "policy": "No AI tools.", "consent": True})
    assert session.status_code in (200, 201), session.text
    sid = session.json()["id"]
    answer = env.post(f"/api/sessions/{sid}/answers", json={"question": "How?", "answer": "Carefully.", "references": []})
    assert answer.status_code == 201, answer.text
    aid = answer.json()["id"]
    edit = env.put(f"/api/sessions/{sid}/answers/{aid}", json={"question": "How?", "answer": "Very carefully.", "references": []})
    assert edit.status_code == 200, edit.text  # edits are not new answers

    body = env.get("/api/admin/usage?days=7").json()
    today = body["daily"][0]
    assert body["days"] == 7 and len(body["daily"]) == 7 and today["day"] == usage_events.today()
    assert today["visitors"] == 1 and today["home"] == 1 and today["signin_page"] == 1
    assert today["interviews"] == 1 and today["answers"] == 1 and today["new_accounts"] == 1
    assert body["totals"]["interviews"] == 1 and body["accounts_available"] is True
    person = body["people"][0]
    assert person["email"] == "owner@example.invalid" and person["operator"] is True and person["role"] == "admin"
    assert person["active_sessions"] >= 1
    assert {"auth.signup"} <= {event["action"] for event in body["recent"]}
    assert body["ai_setup"] == {"connected": 0, "enabled": 0, "with_key": 0, "env_fallbacks": []}
    assert env.get("/api/admin/usage?days=0").status_code == 422
    assert env.get("/api/admin/usage?days=366").status_code == 422


def test_usage_works_without_an_operator_email(env, monkeypatch):
    monkeypatch.setenv("ADMIN_EMAILS", "admin1@example.invalid")
    monkeypatch.setenv("ADMIN_BOOTSTRAP_SECRET", "bootstrap-fixture-secret")
    signup = env.post("/api/integrations/access/signup",
                      json={"email": "admin1@example.invalid", "password": "strong-password-1", "adminSecret": "bootstrap-fixture-secret"})
    assert signup.status_code == 200
    response = env.get("/api/admin/usage")
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["days"] == 30 and [p["operator"] for p in body["people"]] == [False]
