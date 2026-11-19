"""Tier 5 adversarial backend coverage for T5-02, T5-05, T5-06, T5-07, T5-14, and T5-15."""
import asyncio, base64, json, os, socket
from pathlib import Path
from unittest.mock import AsyncMock
from uuid import uuid4

from fastapi import HTTPException
from fastapi.testclient import TestClient
import httpx
import pytest

from api import (
    access, account_auth, account_db, authoring, backup_schema, integrations, local_boundary,
    model_probe, model_registry, model_resolver, rate_limit, scoring_hooks, secret_box,
    security_headers, ssrf_guard, store,
)
from api.account_server import app as standalone
from api.main import app


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "tier5-backend-secret")
    for k in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_PUBLIC_ORIGIN",
              "INTERVIEWCHECK_PRODUCTION", "INTERVIEWCHECK_MODEL_SECRET_FILE", "OPENAI_API_KEY",
              "ANTHROPIC_API_KEY", "AZURE_OPENAI_API_KEY", "DEEPGRAM_API_KEY"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda host, port=443: ["93.184.216.34"])
    monkeypatch.setattr(ssrf_guard.socket, "getaddrinfo", lambda host, port, type=0: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", port))])
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        yield client


def _seed_admin(email: str = "admin@example.invalid") -> tuple[str, str]:
    uid, ts = str(uuid4()), account_db.now()
    with account_db.connection(write=True) as db:
        db.execute("INSERT INTO users(id,email,password_hash,role,disabled,created_at,updated_at) VALUES (?,?,?,?,0,?,?)",
                   (uid, email, account_db.DECOY, "admin", ts, ts))
        return uid, account_db.issue(db, uid, "pytest")


def _reg(*, slug: str, provider: str, capability: str, model_id: str, secret: str | None = "sk-tier5-1234",
         endpoint: str | None = None, api_version: str | None = None, enabled: bool = True,
         is_default: bool = False, priority: int = 100) -> dict:
    uid = str(uuid4())
    with store.connection(write=True) as db:
        return model_registry.create_model(
            db, model_uuid=uid, slug=slug, display_name=slug, provider=provider, capability=capability,
            model_id=model_id, endpoint=endpoint, api_version=api_version, parameters={"fallback_priority": priority},
            encrypted_api_key=secret_box.encrypt_secret(secret, aad=uid) if secret else None,
            key_hint=secret_box.mask_key_hint(secret) if secret else None, enabled=enabled, is_default=is_default,
        )


def _run_probe_race(monkeypatch, tok: str, mid: str, action):
    async def scenario():
        entered, release = asyncio.Event(), asyncio.Event()

        async def paused(row, *, api_key):
            entered.set()
            await release.wait()
            return model_probe.ProbeOutcome(ok=True, status="connected", http_status=200, latency_ms=10, last_error=None, checked_at="2026-11-19T07:00:00Z")

        monkeypatch.setattr(model_probe, "probe_model", paused)
        headers = {"X-InterviewCheck": "1", "Cookie": f"{access.COOKIE}={tok}"}
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://127.0.0.1", headers=headers) as ac:
            task = asyncio.create_task(ac.post(f"/api/admin/models/{mid}/probe"))
            await entered.wait()
            assert (await action(ac)).status_code == 200
            release.set()
            return await task, (await ac.get("/api/admin/models")).json()["models"]

    return asyncio.run(scenario())


def _assert_http(status: int, fn, *args, **kwargs):
    with pytest.raises(HTTPException) as exc:
        fn(*args, **kwargs)
    assert exc.value.status_code == status


# --- T5-02: model_admin.py TOCTOU races ---


def test_t5_02_patch_during_async_dns_race(env, monkeypatch):
    _, tok = _seed_admin()
    m = _reg(slug="compat-race", provider="openai_compatible", capability="reference",
             model_id="llama-3", endpoint="https://llm.example.com/v1", secret="sk-orig-1111")

    async def scenario():
        entered, release, orig = asyncio.Event(), asyncio.Event(), ssrf_guard.validate_endpoint_url_async

        async def paused(url, *, provider, resolve_dns=True):
            entered.set()
            await release.wait()
            return await orig(url, provider=provider, resolve_dns=resolve_dns)

        monkeypatch.setattr(ssrf_guard, "validate_endpoint_url_async", paused)
        headers = {"X-InterviewCheck": "1", "Cookie": f"{access.COOKIE}={tok}"}
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://127.0.0.1", headers=headers) as ac:
            task_a = asyncio.create_task(ac.patch(f"/api/admin/models/{m['id']}", json={"endpoint": "https://llm.example.com/v2"}))
            await entered.wait()
            assert (await ac.patch(f"/api/admin/models/{m['id']}", json={"apiKey": "sk-rotated-2222"})).status_code == 200
            release.set()
            resp_a = await task_a
            listed = (await ac.get("/api/admin/models")).json()["models"][0]
            assert resp_a.status_code == 409 and listed["key_hint"] == "...2222"

    asyncio.run(scenario())


def test_t5_02_patch_during_probe_race(env, monkeypatch):
    _, tok = _seed_admin()
    m = _reg(slug="oa-probe-race", provider="openai", capability="reference", model_id="gpt-4o", secret="sk-orig-1111")
    probe_resp, models = _run_probe_race(monkeypatch, tok, m["id"], lambda ac: ac.patch(f"/api/admin/models/{m['id']}", json={"apiKey": "sk-new-2222"}))
    assert probe_resp.status_code == 409 and models[0]["status"] == "unverified"


def test_t5_02_delete_during_probe_does_not_resurrect_model(env, monkeypatch):
    _, tok = _seed_admin()
    m = _reg(slug="oa-del-race", provider="openai", capability="reference", model_id="gpt-4o", secret="sk-orig-1111")
    probe_resp, models = _run_probe_race(monkeypatch, tok, m["id"], lambda ac: ac.delete(f"/api/admin/models/{m['id']}"))
    assert probe_resp.status_code in {404, 409} and models == []


# --- T5-05: scoring_hooks.py & prompt_framing.py ---


def test_t5_05_judge_signals_keys_strip_control_chars(env, monkeypatch):
    _reg(slug="judge-ctrl", provider="openai", capability="judge", model_id="gpt-4o", is_default=True)
    captured = {}

    async def fake_fetch(name, method, url, **kwargs):
        captured.update(json.loads(kwargs["json"]["messages"][-1]["content"]))
        return {"choices": [{"finish_reason": "stop", "message": {"content": '{"likelihood":50,"confidence":"medium"}'}}]}

    monkeypatch.setattr(scoring_hooks, "fetch_json", fake_fetch)
    assert env.post("/api/scoring/judge", json={"question": "Q?", "answer": "A", "signals": {"bad\x00key\x07\n": 1.0}}).status_code == 200
    assert all("\x00" not in k and "\x07" not in k and "\n" not in k for k in captured["signals"])


def test_t5_05_cosine_semantic_and_judge_branches(env, monkeypatch):
    _assert_http(502, scoring_hooks._cosine_similarity, [1.0], [1.0, 2.0])
    assert scoring_hooks._cosine_similarity([0.0, 0.0], [1.0, 0.0]) == 0.0
    _assert_http(502, scoring_hooks._cosine_similarity, [float("nan")], [1.0])

    assert env.post("/api/scoring/semantic", json={"answer": "A", "references": [{"label": "P", "text": "T", "permitted": True}]}).json()["available"] is False
    _reg(slug="emb-oa", provider="openai", capability="embedding", model_id="text-embedding-3-small", is_default=True)
    monkeypatch.setattr(scoring_hooks, "fetch_json", AsyncMock(return_value={"data": [{"index": 0, "embedding": [1.0, 0.0]}]}))
    assert env.post("/api/scoring/semantic", json={"answer": "A", "references": [{"label": "R", "text": "T", "permitted": False}]}).status_code == 502

    az = _reg(slug="emb-az", provider="azure_openai", capability="embedding", model_id="dep-emb", endpoint="https://res.openai.azure.com", api_version="2024-10-21")
    comp = _reg(slug="emb-cp", provider="openai_compatible", capability="embedding", model_id="bge", endpoint="https://emb.example.com", secret=None)
    calls = []

    async def fake_emb(name, method, url, **kwargs):
        calls.append((url, kwargs.get("headers")))
        return {"data": [{"index": 0, "embedding": [1.0, 0.0]}, {"index": 1, "embedding": [0.0, 1.0]}]}

    monkeypatch.setattr(scoring_hooks, "fetch_json", fake_emb)
    assert env.post("/api/scoring/semantic", json={"answer": "A", "references": [{"label": "R", "text": "T"}], "model_slug": az["slug"]}).status_code == 200
    assert env.post("/api/scoring/semantic", json={"answer": "A", "references": [{"label": "R", "text": "T"}], "model_slug": comp["slug"]}).status_code == 200
    assert calls[0][0] == "https://res.openai.azure.com/openai/deployments/dep-emb/embeddings?api-version=2024-10-21"
    assert calls[1] == ("https://emb.example.com/v1/embeddings", {})
    _assert_http(503, scoring_hooks._embedding_request, model_resolver.ResolvedModel("registry", None, None, "A", "anthropic", "embedding", "m", "k", None, None, {}, "connected"), ["x"])

    _reg(slug="jdg-oa", provider="openai", capability="judge", model_id="gpt-4o", is_default=True)
    monkeypatch.setattr(scoring_hooks, "fetch_json", AsyncMock(return_value={"choices": [{"finish_reason": "stop", "message": {"content": '{"likelihood":true,"confidence":"high"}'}}]}))
    assert env.post("/api/scoring/judge", json={"question": "Q?", "answer": "A"}).status_code == 502
    monkeypatch.setattr(scoring_hooks, "fetch_json", AsyncMock(return_value={"choices": [{"finish_reason": "stop", "message": {"content": '{"likelihood":-5,"confidence":"bogus"}'}}]}))
    ok = env.post("/api/scoring/judge", json={"question": "Q?", "answer": "A"})
    assert ok.status_code == 200 and ok.json()["likelihood"] == 0 and ok.json()["confidence"] == "medium"


# --- T5-06: security_headers.py ---


def test_t5_06_304_non_html_asset_emits_static_asset_csp(tmp_path):
    static = tmp_path / "out"
    static.mkdir()
    (static / "appearance.js").write_text("window.x=1;")

    async def inner(scope, receive, send):
        await send({"type": "http.response.start", "status": 304, "headers": []})
        await send({"type": "http.response.body", "body": b""})

    mw = security_headers.SecurityHeadersMiddleware(inner, static_dir=static)
    captured = {}

    async def run():
        async def send(msg):
            if msg["type"] == "http.response.start":
                captured.update({k.decode().lower(): v.decode() for k, v in msg["headers"]})
        await mw({"type": "http", "path": "/appearance.js", "scheme": "http", "headers": []}, None, send)

    asyncio.run(run())
    assert captured["content-security-policy"] == security_headers._STATIC_ASSET_CSP


def test_t5_06_symlink_escape_and_mtime_cache_invalidation(tmp_path):
    static = tmp_path / "out"
    static.mkdir()
    outside = tmp_path / "secret.html"
    outside.write_text("<script>alert(1)</script>")
    (static / "escape.html").symlink_to(outside)
    index = static / "index.html"
    index.write_text("<script>window.v=1;</script>")

    mw = security_headers.SecurityHeadersMiddleware(lambda *a: None, static_dir=static)
    assert mw._resolve_static_html("/escape.html", 200) is None
    h1 = mw._script_hashes(index)
    index.write_text("<script>window.v=2;</script>")
    st = index.stat()
    os.utime(index, ns=(st.st_atime_ns, st.st_mtime_ns + 1_000_000_000))
    h2 = mw._script_hashes(index)
    assert len(h1) == len(h2) == 1 and h2 != h1


# --- T5-07: model_resolver.py & authoring.py ---


def test_t5_07_fallback_priority_secretbox_503_dispatch_and_partial_references(env, monkeypatch):
    _reg(slug="ref-low", provider="openai", capability="reference", model_id="gpt-4o-mini", priority=50)
    _reg(slug="ref-high", provider="openai", capability="reference", model_id="gpt-4o", priority=5)
    assert model_resolver.resolve_or_503("reference").slug == "ref-high"

    _reg(slug="emb-sec", provider="openai", capability="embedding", model_id="text-embedding-3-small", is_default=True)
    _reg(slug="jdg-sec", provider="openai", capability="judge", model_id="gpt-4o", is_default=True)
    _reg(slug="dg-sec", provider="deepgram", capability="transcription", model_id="nova-2", is_default=True)
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "wrong-master-key")
    assert env.post("/api/authoring/reference", json={"provider": "ref-high", "style": "Talking points", "role": "SRE", "question": "Q?"}).status_code == 503
    assert env.post("/api/integrations/reference", json={"role": "SRE", "question": "Q?"}).status_code == 503
    assert env.post("/api/scoring/judge", json={"question": "Q?", "answer": "A"}).status_code == 503
    assert env.post("/api/scoring/semantic", json={"answer": "A", "references": [{"label": "R", "text": "T"}]}).status_code == 503
    assert env.post("/api/integrations/transcribe", content=b"wav", headers={"Content-Type": "audio/wav", "X-Send-Audio": "deepgram"}).status_code == 503
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "tier5-backend-secret")

    az = model_resolver.ResolvedModel("registry", None, None, "Az", "azure_openai", "reference", "dep", "az-k", "https://res.openai.azure.com", "2024-10-21", {}, "connected")
    seen = {}

    async def fake_az(label, method, url, **kwargs):
        seen.update({"url": url, "headers": kwargs["headers"], "params": kwargs["params"]})
        return {"choices": [{"finish_reason": "stop", "message": {"content": "Az ok"}}]}

    assert asyncio.run(model_resolver.dispatch_completion(az, "sys", "usr", fetch_fn=fake_az)) == ("dep", "Az ok")
    assert seen == {"url": "https://res.openai.azure.com/openai/deployments/dep/chat/completions", "headers": {"api-key": "az-k"}, "params": {"api-version": "2024-10-21"}}

    comp = model_resolver.ResolvedModel("registry", None, None, "Cp", "openai_compatible", "reference", "llama", "", "https://llm.example.com", None, {}, "connected")
    assert asyncio.run(model_resolver.dispatch_completion(comp, "s", "u", fetch_fn=AsyncMock(return_value={"choices": [{"finish_reason": "stop", "message": {"content": "ok"}}]}))) == ("llama", "ok")
    for bad in ({"choices": [{"finish_reason": "length", "message": {"content": "cut"}}]}, {"choices": [{"finish_reason": "stop", "message": {"content": "x" * 24001}}]}):
        with pytest.raises(HTTPException) as exc:
            asyncio.run(model_resolver.dispatch_completion(comp, "s", "u", fetch_fn=AsyncMock(return_value=bad)))
        assert exc.value.status_code == 502

    ant = model_resolver.ResolvedModel("registry", None, None, "Ant", "anthropic", "reference", "claude", "k", None, None, {}, "connected")
    with pytest.raises(HTTPException) as ant_exc:
        asyncio.run(model_resolver.dispatch_completion(ant, "s", "u", fetch_fn=AsyncMock(return_value={"stop_reason": "max_tokens", "content": [{"type": "text", "text": "hi"}]})))
    assert ant_exc.value.status_code == 502

    _reg(slug="ref-ant", provider="anthropic", capability="reference", model_id="claude-sonnet-4-6", is_default=True)

    async def partial_fetch(label, method, url, **kwargs):
        if "anthropic" in url:
            raise HTTPException(502, "Anthropic failed")
        return {"choices": [{"finish_reason": "stop", "message": {"content": "OpenAI recovered"}}]}

    monkeypatch.setattr(authoring, "fetch_json", partial_fetch)
    res = env.post("/api/authoring/references", json={"role": "SRE", "question": "Q?", "existing_reference_count": 0,
                                                       "pairs": [{"provider": "Anthropic", "style": "Talking points"}, {"provider": "OpenAI", "style": "Spoken answer"}]})
    assert res.status_code == 200
    results = res.json()["results"]
    assert "error" in results[0] and results[1]["source"]["text"] == "OpenAI recovered"


# --- T5-14: model_registry.py & model_admin.py ---


def test_t5_14_registry_and_patch_edges(env):
    _, tok = _seed_admin()
    env.cookies.set(access.COOKIE, tok)
    assert model_registry.parse_parameters("[]") == model_registry.DEFAULT_PARAMETERS
    assert model_registry.parse_parameters("bad-json") == model_registry.DEFAULT_PARAMETERS

    with store.connection(write=True) as db:
        assert model_registry.generate_unique_slug(db, "!") == "model"
        model_registry.create_model(db, model_uuid=str(uuid4()), slug="model", display_name="M", provider="openai", capability="reference", model_id="gpt-4o", endpoint=None, api_version=None, parameters={}, encrypted_api_key=None, key_hint=None, enabled=True, is_default=False)
        s2 = model_registry.generate_unique_slug(db, "!")
        assert s2.startswith("model-") and s2 != "model"

    ant = _reg(slug="ant-patch", provider="anthropic", capability="reference", model_id="claude-sonnet-4-6")
    assert env.patch(f"/api/admin/models/{ant['id']}", json={"capability": "embedding"}).status_code == 422
    comp = _reg(slug="comp-norm", provider="openai_compatible", capability="reference", model_id="llama-3", endpoint="https://llm.example.com/v1")
    norm = env.patch(f"/api/admin/models/{comp['id']}", json={"endpoint": "https://LLM.Example.COM/v1/"})
    assert norm.status_code == 200 and norm.json()["model"]["endpoint"] == "https://llm.example.com/v1"

    dis = _reg(slug="dis-probe", provider="openai", capability="reference", model_id="gpt-4o", enabled=False)
    with store.connection(write=True) as db:
        probed = model_registry.record_probe_result(db, dis["id"], ok=True, latency_ms=25, error=None, checked_at="2026-11-19T07:10:00Z")
        assert probed["status"] == "disabled" and probed["last_checked_at"] == "2026-11-19T07:10:00Z"
        assert model_registry.toggle_model(db, dis["id"], enabled=True)["status"] == "connected"


# --- T5-15: rate_limit, local_boundary, access, account_*, secret_box, backup, integrations ---


def test_t5_15_rate_limit_local_boundary_and_access(env, monkeypatch):
    lim = rate_limit.FixedWindowRateLimiter(5, 60)
    for i in range(5000):
        lim.hit(f"k-{i}")
    lim.hit("k-overflow")
    assert len(lim._buckets) == 5000 and "k-0" not in lim._buckets and "k-overflow" in lim._buckets

    async def run_boundary(headers, chunks):
        sent, queue = [], list(chunks)
        mw = local_boundary.LocalBoundary(lambda s, r, se: se({"type": "http.response.start", "status": 200, "headers": []}))
        await mw({"type": "http", "method": "POST", "scheme": "http", "path": "/api/sessions", "headers": headers},
                 lambda: asyncio.sleep(0, result=queue.pop(0) if queue else {"type": "http.disconnect"}),
                 lambda msg: asyncio.sleep(0, result=sent.append(msg)))
        return sent[0]["status"]

    base_h = [(b"host", b"127.0.0.1"), (b"x-interviewcheck", b"1")]
    assert asyncio.run(run_boundary(base_h + [(b"content-length", b"abc")], [])) == 400
    assert asyncio.run(run_boundary(base_h + [(b"content-length", b"-1")], [])) == 413
    assert asyncio.run(run_boundary(base_h, [{"type": "http.request", "body": b"x" * (1024 * 1024 + 1), "more_body": True},
                                           {"type": "http.request", "body": b"x" * (1024 * 1024), "more_body": False}])) == 413

    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "https://accounts.example.invalid")
    _assert_http(503, access.account_enabled)
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "remote")
    for bad_u in ("http://remote.example", "https://user:pass@remote.example", "https://remote.example?x=1", "https://remote.example#f"):
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", bad_u)
        _assert_http(503, access.access_url, "me")


def test_t5_15_accounts_secret_box_backup_and_status(env, tmp_path, monkeypatch):
    for bad_tok in ("Bearer mm_" + "a" * 36, "Bearer mm_" + "a" * 126):
        _assert_http(401, account_auth.authenticate, bad_tok)

    uid, tok = _seed_admin(email="admin1@example.invalid")
    with account_db.connection(write=True) as db:
        soon = account_db.now() + 1000
        db.execute("UPDATE sessions SET expires_at=? WHERE token_hash=?", (soon, account_db.digest(tok)))
    account_auth.authenticate(f"Bearer {tok}")
    with account_db.connection() as db:
        assert db.execute("SELECT expires_at FROM sessions WHERE token_hash=?", (account_db.digest(tok),)).fetchone()[0] > soon + account_db.DAY

    ts = account_db.now()
    with account_db.connection(write=True) as db:
        for i in range(3):
            db.execute("INSERT INTO users(id,email,password_hash,role,disabled,created_at,updated_at) VALUES (?,?,?,?,0,?,?)",
                       (str(uuid4()), f"tie{i}@example.invalid", account_db.DECOY, "user", ts + 1000, ts + 1000))
    auth_h = {"Authorization": f"Bearer {tok}", "X-InterviewCheck": "1"}
    with TestClient(standalone) as s:
        assert s.get("/v1/admin/users?cursor=bad", headers=auth_h).status_code == 422
        p1 = s.get("/v1/admin/users?limit=2", headers=auth_h).json()
        p2 = s.get(f"/v1/admin/users?limit=2&cursor={p1['nextCursor']}", headers=auth_h).json()
        ids = [u["user"]["id"] for u in p1["users"] + p2["users"]]
        assert len(ids) == 4 and len(set(ids)) == 4
        assert s.patch(f"/v1/admin/users/{uid}", json={"complimentaryUntil": "2027-01-01T00:00:00"}, headers=auth_h).status_code == 422
        assert s.post("/v1/auth/login", content="not-json", headers={"Content-Type": "text/plain", "X-InterviewCheck": "1"}).status_code == 415
        assert s.post("/v1/auth/logout", headers=auth_h).status_code == 204

    key_path = tmp_path / "custom.key"
    monkeypatch.delenv("INTERVIEWCHECK_MODEL_SECRET_KEY", raising=False)
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_FILE", str(key_path))
    pre_key, orig_open = base64.urlsafe_b64encode(b"K" * 32), os.open
    with monkeypatch.context() as mp:
        def racing_open(path, flags, mode=0o777):
            Path(path).write_bytes(pre_key)
            Path(path).chmod(0o600)
            return orig_open(path, flags, mode)

        mp.setattr(os, "open", racing_open)
        tok_file = secret_box.encrypt_secret("sk-race-ok", aad="m1")
    assert secret_box.decrypt_secret(tok_file, aad="m1") == "sk-race-ok"
    master, nonce = secret_box._master_key(), b"\x01" * 16
    prk = secret_box._hkdf_extract(nonce, master)
    ct = secret_box._xor_ctr(secret_box._hkdf_expand(prk, secret_box.ENC_INFO, 32), nonce, b"\xff\xfe")
    tag = secret_box._compute_tag(secret_box._hkdf_expand(prk, secret_box.MAC_INFO, 32), nonce, "m1", ct)
    with pytest.raises(secret_box.SecretBoxError):
        secret_box.decrypt_secret("v1:" + base64.urlsafe_b64encode(nonce + tag + ct).decode("ascii"), aad="m1")

    sid = env.post("/api/sessions", json={"candidate": "Ada", "role": "SRE", "policy": "None", "consent": True}).json()["id"]
    single = env.get(f"/api/backups/workspace?session_id={sid}")
    assert single.status_code == 200 and single.json()["roles"] == []
    monkeypatch.setattr(backup_schema, "LIMIT", 10)
    assert env.get("/api/backups/workspace").status_code == 413
    assert env.post("/api/backups/restore", content=b"{}", headers={"X-Backup-Preview": "short"}).status_code == 422

    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    env.cookies.set(access.COOKIE, "mm_forged_cookie_value_12345678901234567890")
    st = env.get("/api/integrations/status")
    assert st.status_code == 200 and st.json()["signedIn"] is False
