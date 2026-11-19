"""Transcribe a selected audio stream or a recording through the same provider as the Mac app."""
import asyncio
from collections.abc import Callable
import json
import time
from urllib.parse import urlencode
from .origin import browser_origin

from fastapi import APIRouter, Depends, HTTPException, Request, WebSocket, WebSocketDisconnect
from websockets.asyncio.client import connect
from websockets.exceptions import WebSocketException

from . import model_execution, model_resolver, rate_limit, ssrf_guard
from .access import require_entitlement
from .provider_http import fetch_json

router = APIRouter()
LIMIT = 24 * 1024 * 1024
MIME = {"audio/webm", "audio/ogg", "audio/mpeg", "audio/mp3", "audio/mp4", "audio/m4a",
        "audio/x-m4a", "audio/wav", "audio/x-wav", "audio/wave", "audio/flac", "audio/x-flac",
        "video/webm", "video/mp4", "video/quicktime"}


def _deepgram_urls(endpoint: str | None) -> tuple[str, str]:
    if not endpoint:
        return "https://api.deepgram.com/v1/listen", "wss://api.deepgram.com/v1/listen"
    try:
        base = ssrf_guard.validate_endpoint_url(endpoint, provider="openai_compatible", resolve_dns=False).rstrip("/")
    except ssrf_guard.SSRFValidationError as exc:
        raise HTTPException(503, "Configure a valid HTTPS transcription endpoint.") from exc
    http_url = base if base.endswith("/listen") else (f"{base}/listen" if base.endswith("/v1") else f"{base}/v1/listen")
    return http_url, "wss://" + http_url.removeprefix("https://")


@router.post("/transcribe", dependencies=[Depends(require_entitlement), Depends(rate_limit.limit(rate_limit.INTEGRATION_REMOTE))])
async def transcribe(request: Request):
    if request.headers.get("x-send-audio") != "deepgram":
        raise HTTPException(400, "Confirm audio transfer to Deepgram.")
    kind = request.headers.get("content-type", "").split(";")[0].lower()
    if kind not in MIME:
        raise HTTPException(415, "Select a WAV, M4A, MP3, Ogg, FLAC, WebM, MP4 or MOV file.")
    model_execution.resolve_candidates("transcription")
    audio = bytearray()
    async for chunk in request.stream():
        if len(audio) + len(chunk) > LIMIT:
            raise HTTPException(413, "The recording exceeds 24 MiB.")
        audio.extend(chunk)
    if not audio:
        raise HTTPException(422, "The recording is empty.")
    return await transcribe_bytes(bytes(audio), kind)


async def transcribe_bytes(data: bytes, kind: str, *, on_usage: Callable[[int, int], None] | None = None):
    _, segments = await model_execution.execute_transcription_chain(
        data,
        kind,
        url_builder=_deepgram_urls,
        fetch_fn=fetch_json,
        on_usage=on_usage,
    )
    return {"segments": segments}


def same_local_origin(ws: WebSocket) -> bool:
    expected = browser_origin(ws.headers, ws.url.scheme)
    return expected is not None and ws.headers.get("origin") == expected


def _live_candidates() -> list[tuple[model_resolver.ResolvedModel, str]]:
    candidates = model_execution.resolve_candidates("transcription")
    budget_blocked = False
    last_exc: HTTPException | None = None
    ready: list[tuple[model_resolver.ResolvedModel, str]] = []
    for candidate in candidates:
        decision = model_execution._check_target_budget(candidate)
        if decision is not None and not decision.allowed:
            budget_blocked = True
            continue
        try:
            _, ws_base = _deepgram_urls(candidate.endpoint)
            ready.append((candidate, ws_base))
        except HTTPException as exc:
            last_exc = exc
    if ready:
        return ready
    if budget_blocked:
        raise HTTPException(429, "Model budget ceiling reached.")
    if last_exc is not None:
        raise last_exc
    raise HTTPException(503, "Configure an enabled transcription model before running this action.")


async def relay_audio(browser: WebSocket, provider):
    async def upload():
        size = 0
        while True:
            packet = await browser.receive()
            if packet["type"] == "websocket.disconnect":
                raise WebSocketDisconnect()
            if packet.get("text") == "finish":
                await provider.send('{"type":"CloseStream"}')
                return
            frame = packet.get("bytes")
            if not frame or len(frame) > 512 * 1024:
                raise ValueError("Invalid audio packet.")
            size += len(frame)
            if size > LIMIT:
                raise ValueError("The audio stream reached 24 MiB.")
            await provider.send(frame)

    async def download():
        async for message in provider:
            result = json.loads(message)
            if result.get("type") == "Error":
                raise ValueError("Deepgram stopped the stream.")
            if result.get("type") == "Results" and result.get("is_final"):
                words = result["channel"]["alternatives"][0]["transcript"]
                if isinstance(words, str) and words.strip():
                    await browser.send_json({"text": words})

    sender = asyncio.create_task(upload())
    receiver = asyncio.create_task(download())
    try:
        done, _ = await asyncio.wait({sender, receiver}, return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            task.result()
        if sender in done:
            await asyncio.wait_for(receiver, timeout=10)
        else:
            raise ValueError("The transcription stream ended before capture stopped.")
    finally:
        for task in (sender, receiver):
            task.cancel()
        await asyncio.gather(sender, receiver, return_exceptions=True)


@router.websocket("/live")
async def live(ws: WebSocket):
    if not same_local_origin(ws):
        await ws.close(code=1008)
        return
    try:
        await require_entitlement(ws)
        candidates = _live_candidates()
    except HTTPException:
        await ws.close(code=1008)
        return
    await ws.accept()
    started = time.monotonic()
    target: model_resolver.ResolvedModel | None = None
    provider_attempted = False
    ready_sent = False
    try:
        if await asyncio.wait_for(ws.receive_text(), 10) != "send-audio-to-deepgram":
            await ws.close(code=1008)
            return
        ws_base: str | None = None
        last_quota: HTTPException | None = None
        for cand, base in candidates:
            rpm_limit = model_execution._rpm_limit(cand)
            if cand.id is not None and rpm_limit is not None:
                try:
                    model_execution.QUOTA_LIMITER.consume(cand.id, rpm_limit)
                except HTTPException as exc:
                    last_quota = exc
                    continue
            target, ws_base = cand, base
            break
        if target is None or ws_base is None:
            assert last_quota is not None
            raise last_quota
        query = urlencode({"model": target.model_id or "nova-2", "punctuate": "true"})
        url = f"{ws_base}?{query}"
        provider_attempted = True
        started = time.monotonic()
        async with connect(url, additional_headers={"Authorization": f"Token {target.api_key}"}, open_timeout=10) as provider:
            await ws.send_json({"ready": True})
            ready_sent = True
            await asyncio.wait_for(relay_audio(ws, provider), timeout=1800)
        elapsed = int((time.monotonic() - started) * 1000)
        model_execution._record_outcome(target, ok=True, http_status=200, latency_ms=elapsed, error=None)
        await ws.close()
    except WebSocketDisconnect:
        if ready_sent and target is not None:
            elapsed = int((time.monotonic() - started) * 1000)
            model_execution._record_outcome(target, ok=True, http_status=200, latency_ms=elapsed, error=None)
        return
    except HTTPException as exc:
        try:
            await ws.send_json({"error": str(exc.detail)})
            await ws.close(code=1011)
        except (RuntimeError, WebSocketDisconnect):
            pass
    except (TimeoutError, OSError, WebSocketException, ValueError, IndexError, KeyError, TypeError) as exc:
        if provider_attempted and target is not None:
            elapsed = int((time.monotonic() - started) * 1000)
            model_execution._record_outcome(
                target, ok=False, http_status=502, latency_ms=elapsed, error=str(exc) or exc.__class__.__name__,
            )
        try:
            await ws.send_json({"error": "The transcription stream stopped. Check the input and provider connection."})
            await ws.close(code=1011)
        except (RuntimeError, WebSocketDisconnect):
            pass  # Browser already closed its stream.
