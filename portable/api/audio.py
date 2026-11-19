"""Transcribe a selected audio stream or a recording through the same provider as the Mac app."""
import asyncio
import json
from urllib.parse import urlencode
from .origin import browser_origin

from fastapi import APIRouter, Depends, HTTPException, Request, WebSocket, WebSocketDisconnect
from websockets.asyncio.client import connect
from websockets.exceptions import WebSocketException

from . import model_resolver, ssrf_guard
from .access import require_entitlement
from .provider_http import fetch_json

_ORIG_FETCH_JSON = fetch_json
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


@router.post("/transcribe", dependencies=[Depends(require_entitlement)])
async def transcribe(request: Request):
    if request.headers.get("x-send-audio") != "deepgram":
        raise HTTPException(400, "Confirm audio transfer to Deepgram.")
    kind = request.headers.get("content-type", "").split(";")[0].lower()
    if kind not in MIME:
        raise HTTPException(415, "Select a WAV, M4A, MP3, Ogg, FLAC, WebM, MP4 or MOV file.")
    model_resolver.resolve_or_503("transcription")
    audio = bytearray()
    async for chunk in request.stream():
        if len(audio) + len(chunk) > LIMIT:
            raise HTTPException(413, "The recording exceeds 24 MiB.")
        audio.extend(chunk)
    if not audio:
        raise HTTPException(422, "The recording is empty.")
    return await transcribe_bytes(bytes(audio), kind)


async def transcribe_bytes(data: bytes, kind: str):
    target = model_resolver.resolve_or_503("transcription")
    http_url, _ = _deepgram_urls(target.endpoint)
    model_id = target.model_id or "nova-2"
    raw_timeout = target.config.get("timeout_s")
    timeout = min(max(float(raw_timeout if raw_timeout is not None else 180.0), 10.0), 300.0)
    extra_opts = {"ssrf_safe": True} if fetch_json is _ORIG_FETCH_JSON else {}
    data = await fetch_json("Deepgram", "POST", http_url,
                            params={"model": model_id, "diarize": "true", "utterances": "true", "punctuate": "true"},
                            headers={"Authorization": f"Token {target.api_key}", "Content-Type": kind},
                            content=data, timeout=timeout, limit=12_000_000, **extra_opts)
    try:
        results = data["results"]
        segments = [{"speaker": str(item.get("speaker", "Unknown")), "text": item["transcript"]}
                    for item in results.get("utterances", []) if isinstance(item["transcript"], str) and item["transcript"].strip()]
        if not segments:
            text = results["channels"][0]["alternatives"][0]["transcript"]
            if isinstance(text, str) and text.strip():
                segments.append({"speaker": "Unknown", "text": text})
    except (IndexError, AttributeError, KeyError, TypeError) as exc:
        raise HTTPException(502, "Deepgram returned an unreadable transcript.") from exc
    if not segments:
        raise HTTPException(422, "Deepgram found no speech in the recording.")
    return {"segments": segments}


def same_local_origin(ws: WebSocket) -> bool:
    expected = browser_origin(ws.headers, ws.url.scheme)
    return expected is not None and ws.headers.get("origin") == expected


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
        target = model_resolver.resolve_or_503("transcription")
        _, ws_base = _deepgram_urls(target.endpoint)
    except HTTPException:
        await ws.close(code=1008)
        return
    await ws.accept()
    try:
        if await asyncio.wait_for(ws.receive_text(), 10) != "send-audio-to-deepgram":
            await ws.close(code=1008)
            return
        query = urlencode({"model": target.model_id or "nova-2", "punctuate": "true"})
        url = f"{ws_base}?{query}"
        async with connect(url, additional_headers={"Authorization": f"Token {target.api_key}"}, open_timeout=10) as provider:
            await ws.send_json({"ready": True})
            await asyncio.wait_for(relay_audio(ws, provider), timeout=1800)
        await ws.close()
    except WebSocketDisconnect:
        return
    except (TimeoutError, OSError, WebSocketException, ValueError, IndexError, KeyError, TypeError):
        try:
            await ws.send_json({"error": "The transcription stream stopped. Check the input and provider connection."})
            await ws.close(code=1011)
        except (RuntimeError, WebSocketDisconnect):
            pass  # Browser already closed its stream.
