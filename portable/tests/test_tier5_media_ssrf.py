"""Tier 5 adversarial tests for audio WS/HTTP boundaries (T5-03) and SSRF/probe paths (T5-04)."""
import asyncio
from contextlib import asynccontextmanager
import json
import socket
from unittest.mock import AsyncMock
from uuid import uuid4

from fastapi import HTTPException
from fastapi.testclient import TestClient
import httpx
import pytest
from starlette.websockets import WebSocketDisconnect

from api import audio, model_probe, model_registry, secret_box, ssrf_guard, store
from api.main import app


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "tier5-media-ssrf-secret")
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_PUBLIC_ORIGIN", "DEEPGRAM_API_KEY"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda host, port=443: ["93.184.216.34"])
    monkeypatch.setattr(ssrf_guard.socket, "getaddrinfo", lambda host, port, type=0: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", port))])
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        yield client


def _register_transcription(*, endpoint: str | None = None, model_id: str = "nova-3"):
    uid = str(uuid4())
    with store.connection(write=True) as db:
        return model_registry.create_model(
            db, model_uuid=uid, slug="dg-tier5", display_name="Deepgram Tier5",
            provider="deepgram", capability="transcription", model_id=model_id,
            endpoint=endpoint, api_version=None, parameters={"fallback_priority": 100},
            encrypted_api_key=secret_box.encrypt_secret("dg-secret-key-9999", aad=uid),
            key_hint="...9999", enabled=True, is_default=True,
        )


def _fake_ws_provider(messages=(), *, fail_on_recv: bool = False):
    @asynccontextmanager
    async def _connect(url, **kwargs):
        class Provider:
            def __init__(self):
                self.sent = []
                self._items = list(messages)

            async def send(self, data):
                self.sent.append(data)

            def __aiter__(self):
                return self

            async def __anext__(self):
                if self._items:
                    return self._items.pop(0)
                if fail_on_recv:
                    raise OSError("upstream reset")
                await asyncio.sleep(0)
                raise StopAsyncIteration

        yield Provider()

    return _connect


# --- T5-03: audio.py live WebSocket & /transcribe boundaries ---


def test_live_ws_cross_origin_entitlement_and_bad_handshake_close_1008(env, monkeypatch):
    _register_transcription()

    with pytest.raises(WebSocketDisconnect) as cross:
        with env.websocket_connect("ws://127.0.0.1/api/integrations/live", headers={"Origin": "https://evil.example"}):
            pass
    assert cross.value.code == 1008

    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    with pytest.raises(WebSocketDisconnect) as unauth:
        with env.websocket_connect("ws://127.0.0.1/api/integrations/live", headers={"Origin": "http://127.0.0.1"}):
            pass
    assert unauth.value.code == 1008
    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_MODE")

    with env.websocket_connect("ws://127.0.0.1/api/integrations/live", headers={"Origin": "http://127.0.0.1"}) as ws:
        ws.send_text("wrong-handshake")
        with pytest.raises(WebSocketDisconnect) as bad_hs:
            ws.receive_text()
        assert bad_hs.value.code == 1008


def test_live_ws_oversized_frame_total_stream_deepgram_error_and_premature_close(env, monkeypatch):
    _register_transcription()
    headers = {"Origin": "http://127.0.0.1"}

    # Frame > 512 KiB -> error JSON + 1011
    monkeypatch.setattr(audio, "connect", lambda *a, **kw: _fake_ws_provider()(*a, **kw))
    with env.websocket_connect("ws://127.0.0.1/api/integrations/live", headers=headers) as ws:
        ws.send_text("send-audio-to-deepgram")
        assert ws.receive_json() == {"ready": True}
        ws.send_bytes(b"x" * (512 * 1024 + 1))
        err = ws.receive_json()
        assert "stopped" in err["error"].lower()
        with pytest.raises(WebSocketDisconnect) as exc:
            ws.receive_json()
        assert exc.value.code == 1011

    # Total stream > 24 MiB -> error JSON + 1011
    async def slow_empty():
        await asyncio.sleep(5)
        return
        yield

    @asynccontextmanager
    async def hanging_provider(*args, **kwargs):
        class Provider:
            async def send(self, data):
                pass

            def __aiter__(self):
                return slow_empty()

        yield Provider()

    monkeypatch.setattr(audio, "connect", hanging_provider)
    with env.websocket_connect("ws://127.0.0.1/api/integrations/live", headers=headers) as ws:
        ws.send_text("send-audio-to-deepgram")
        assert ws.receive_json() == {"ready": True}
        chunk = b"a" * (512 * 1024)
        for _ in range(48):
            ws.send_bytes(chunk)
        ws.send_bytes(b"1")  # 24 MiB + 1 byte
        assert "error" in ws.receive_json()
        with pytest.raises(WebSocketDisconnect) as exc:
            ws.receive_json()
        assert exc.value.code == 1011

    # Deepgram Error JSON event -> error JSON + 1011
    monkeypatch.setattr(
        audio, "connect",
        lambda *a, **kw: _fake_ws_provider([json.dumps({"type": "Error", "message": "bad stream"})])(*a, **kw),
    )
    with env.websocket_connect("ws://127.0.0.1/api/integrations/live", headers=headers) as ws:
        ws.send_text("send-audio-to-deepgram")
        assert ws.receive_json() == {"ready": True}
        assert "error" in ws.receive_json()
        with pytest.raises(WebSocketDisconnect) as exc:
            ws.receive_json()
        assert exc.value.code == 1011

    # Premature provider close before browser sends finish -> error JSON + 1011
    monkeypatch.setattr(audio, "connect", lambda *a, **kw: _fake_ws_provider([])(*a, **kw))
    with env.websocket_connect("ws://127.0.0.1/api/integrations/live", headers=headers) as ws:
        ws.send_text("send-audio-to-deepgram")
        assert ws.receive_json() == {"ready": True}
        assert "error" in ws.receive_json()
        with pytest.raises(WebSocketDisconnect) as exc:
            ws.receive_json()
        assert exc.value.code == 1011


def test_transcribe_limits_empty_audio_channels_fallback_nospeech_and_custom_urls(env, monkeypatch):
    _register_transcription()
    headers = {"Content-Type": "audio/wav", "X-Send-Audio": "deepgram"}

    # Empty audio -> 422 when model exists
    assert env.post("/api/integrations/transcribe", content=b"", headers=headers).status_code == 422

    # >24 MiB streaming -> 413 (both via LocalBoundary and audio.transcribe)
    oversized = b"x" * (audio.LIMIT + 1)
    assert env.post("/api/integrations/transcribe", content=oversized, headers=headers).status_code == 413

    class FakeReq:
        headers = {"x-send-audio": "deepgram", "content-type": "audio/wav"}

        async def stream(self):
            yield b"a" * (16 * 1024 * 1024)
            yield b"b" * (8 * 1024 * 1024 + 1)

    with pytest.raises(HTTPException) as exc:
        asyncio.run(audio.transcribe(FakeReq()))
    assert exc.value.status_code == 413

    # channels[0] fallback when utterances is empty
    monkeypatch.setattr(
        audio, "fetch_json",
        AsyncMock(return_value={"results": {"utterances": [], "channels": [{"alternatives": [{"transcript": "Fallback words"}]}]}}),
    )
    ok = env.post("/api/integrations/transcribe", content=b"RIFF", headers=headers)
    assert ok.status_code == 200 and ok.json() == {"segments": [{"speaker": "Unknown", "text": "Fallback words"}]}

    # No-speech -> 422
    monkeypatch.setattr(
        audio, "fetch_json",
        AsyncMock(return_value={"results": {"utterances": [], "channels": [{"alternatives": [{"transcript": "   "}]}]}}),
    )
    assert env.post("/api/integrations/transcribe", content=b"RIFF", headers=headers).status_code == 422

    # Custom endpoint normalization + SSRF rejection in _deepgram_urls
    assert audio._deepgram_urls("https://dg.example.com") == ("https://dg.example.com/v1/listen", "wss://dg.example.com/v1/listen")
    assert audio._deepgram_urls("https://dg.example.com/v1") == ("https://dg.example.com/v1/listen", "wss://dg.example.com/v1/listen")
    assert audio._deepgram_urls("https://dg.example.com/v1/listen") == ("https://dg.example.com/v1/listen", "wss://dg.example.com/v1/listen")
    with pytest.raises(HTTPException) as bad_url:
        audio._deepgram_urls("http://127.0.0.1/listen")
    assert bad_url.value.status_code == 503


# --- T5-04: ssrf_guard.py & model_probe.py ---


def test_ssrf_guard_teredo_punycode_unix_socket_and_raw_ip(monkeypatch):
    # Teredo IPv6 addresses blocked
    assert ssrf_guard.is_disallowed_ip("2001::1") is True
    assert ssrf_guard.is_disallowed_ip("2001:0000:4136:e378:8000:63bf:3fff:fdd2") is True

    # Valid punycode accepted; invalid IDNA/overlong/empty-label/non-ASCII IDN rejected
    assert ssrf_guard.validate_endpoint_url("https://xn--bcher-kva.example/v1", provider="openai_compatible", resolve_dns=False) == "https://xn--bcher-kva.example/v1"
    for bad_url in (
        f"https://{'a' * 64}.example/v1",
        "https://bad\u200bhost.example/v1",
        "https://bad..host.example/v1",
        "https://bücher.example/v1",
    ):
        with pytest.raises(ssrf_guard.SSRFValidationError):
            ssrf_guard.validate_endpoint_url(bad_url, provider="openai_compatible", resolve_dns=False)

    # SafeNetworkBackend.connect_unix_socket + connect_tcp raw IP literal branch
    backend = ssrf_guard.SafeNetworkBackend()
    with pytest.raises(ssrf_guard.SSRFValidationError):
        asyncio.run(backend.connect_unix_socket("/var/run/docker.sock"))

    with pytest.raises(ssrf_guard.SSRFValidationError):
        asyncio.run(backend.connect_tcp("127.0.0.1", 443))
    with pytest.raises(ssrf_guard.SSRFValidationError):
        asyncio.run(backend.connect_tcp("::1", 443))

    inner = AsyncMock(return_value="raw-ip-stream")
    monkeypatch.setattr(backend._inner, "connect_tcp", inner)
    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda *a, **kw: (_ for _ in ()).throw(AssertionError("should not resolve raw IP")))
    assert asyncio.run(backend.connect_tcp("93.184.216.34", 443)) == "raw-ip-stream"
    assert inner.await_args.args[:2] == ("93.184.216.34", 443)


@pytest.mark.parametrize("code", [301, 302, 307])
def test_probe_blocks_live_http_redirects_to_loopback(monkeypatch, code):
    monkeypatch.setattr(ssrf_guard.socket, "getaddrinfo", lambda host, port, type=0: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", port))])
    seen_urls: list[str] = []

    async def fake_handle(self, request):
        seen_urls.append(str(request.url))
        return httpx.Response(code, headers={"Location": "http://127.0.0.1/latest/meta-data"}, request=request)

    monkeypatch.setattr(ssrf_guard.SafeAsyncTransport, "handle_async_request", fake_handle)
    outcome = asyncio.run(model_probe.probe_model({
        "provider": "openai_compatible",
        "capability": "reference",
        "model_id": "llama-3",
        "endpoint": "https://llm.example.com/v1",
        "api_version": None,
        "parameters": {"timeout_s": 5},
    }, api_key=""))
    assert outcome.ok is False and outcome.http_status == code
    assert f"HTTP {code}" in (outcome.last_error or "") and "Redirects are blocked" in (outcome.last_error or "")
    assert seen_urls == ["https://llm.example.com/v1/models"]


def test_probe_fallbacks_azure_embedding_and_payload_validation(monkeypatch):
    monkeypatch.setattr(ssrf_guard.socket, "getaddrinfo", lambda host, port, type=0: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", port))])

    # Missing key on required provider & invalid model_id
    missing_key = asyncio.run(model_probe.probe_model({
        "provider": "openai", "capability": "reference", "model_id": "gpt-4o", "endpoint": None, "api_version": None,
    }, api_key=""))
    assert missing_key.ok is False and "No API key" in (missing_key.last_error or "")

    bad_id = asyncio.run(model_probe.probe_model({
        "provider": "openai", "capability": "reference", "model_id": "bad model!", "endpoint": None, "api_version": None,
    }, api_key="sk-1234"))
    assert bad_id.ok is False and "invalid" in (bad_id.last_error or "").lower()

    # openai_compatible 404/405 -> POST /embeddings fallback
    for first_status in (404, 405):
        calls = []

        async def send_compat_embed(self, request, **kwargs):
            calls.append((request.method, str(request.url), json.loads(request.content.decode()) if request.content else None))
            if request.url.path.endswith("/models"):
                return httpx.Response(first_status, request=request)
            return httpx.Response(200, json={"data": [{"embedding": [0.1]}]}, request=request)

        monkeypatch.setattr(httpx.AsyncClient, "send", send_compat_embed)
        res = asyncio.run(model_probe.probe_model({
            "provider": "openai_compatible", "capability": "embedding", "model_id": "bge-m3",
            "endpoint": "https://embed.example.com", "api_version": None, "parameters": {},
        }, api_key=""))
        assert res.ok is True and res.status == "connected"
        assert calls == [
            ("GET", "https://embed.example.com/v1/models", None),
            ("POST", "https://embed.example.com/v1/embeddings", {"model": "bge-m3", "input": "ok"}),
        ]

    # azure_openai embedding probe URL + payload
    azure_calls = []

    async def send_azure_embed(self, request, **kwargs):
        azure_calls.append((request.method, str(request.url), json.loads(request.content.decode())))
        return httpx.Response(200, json={"data": [{"embedding": [0.2]}]}, request=request)

    monkeypatch.setattr(httpx.AsyncClient, "send", send_azure_embed)
    az = asyncio.run(model_probe.probe_model({
        "provider": "azure_openai", "capability": "embedding", "model_id": "text-embed",
        "endpoint": "https://res.openai.azure.com", "api_version": "2024-10-21", "parameters": {},
    }, api_key="az-key"))
    assert az.ok is True
    assert azure_calls == [("POST", "https://res.openai.azure.com/openai/deployments/text-embed/embeddings?api-version=2024-10-21", {"input": "probe"})]

    # 200 OK invalid JSON & non-dict JSON & oversized response
    for raw_body, expected_msg in [
        (b"{not-json", "invalid probe JSON"),
        (b"[1, 2, 3]", "unexpected probe payload"),
        (b'"ok"', "unexpected probe payload"),
    ]:
        async def send_bad_json(self, request, **kwargs):
            return httpx.Response(200, content=raw_body, request=request)

        monkeypatch.setattr(httpx.AsyncClient, "send", send_bad_json)
        out = asyncio.run(model_probe.probe_model({
            "provider": "openai", "capability": "reference", "model_id": "gpt-4o", "endpoint": None, "api_version": None,
        }, api_key="sk-1234"))
        assert out.ok is False and expected_msg in (out.last_error or "")

    async def send_huge(self, request, **kwargs):
        return httpx.Response(200, headers={"Content-Length": str(model_probe.MAX_PROBE_RESPONSE_BYTES + 1)}, content=b"{}", request=request)

    monkeypatch.setattr(httpx.AsyncClient, "send", send_huge)
    huge = asyncio.run(model_probe.probe_model({
        "provider": "openai", "capability": "reference", "model_id": "gpt-4o", "endpoint": None, "api_version": None,
    }, api_key="sk-1234"))
    assert huge.ok is False and huge.http_status == 200 and "size limit" in (huge.last_error or "")
