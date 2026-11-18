"""Transcribe a selected audio stream or a recording through the same provider as the Mac app."""
import asyncio
import json
from urllib.parse import urlsplit

from fastapi import APIRouter, Depends, HTTPException, Request, WebSocket, WebSocketDisconnect
from websockets.asyncio.client import connect
from websockets.exceptions import WebSocketException

from .access import require_entitlement
from .provider_http import fetch_json, setting

router = APIRouter()
LIMIT = 24 * 1024 * 1024
MIME = {"audio/webm", "audio/ogg", "audio/mpeg", "audio/mp3", "audio/mp4", "audio/m4a",
        "audio/x-m4a", "audio/wav", "audio/x-wav", "audio/wave", "audio/flac", "audio/x-flac",
        "video/webm", "video/mp4", "video/quicktime"}


@router.post("/transcribe", dependencies=[Depends(require_entitlement)])
async def transcribe(request: Request):
    if request.headers.get("x-send-audio") != "deepgram":
        raise HTTPException(400, "Confirm audio transfer to Deepgram.")
    kind = request.headers.get("content-type", "").split(";")[0].lower()
    if kind not in MIME:
        raise HTTPException(415, "Select a WAV, M4A, MP3, Ogg, FLAC, WebM, MP4 or MOV file.")
    setting("DEEPGRAM_API_KEY")
    audio = bytearray()
    async for chunk in request.stream():
        if len(audio) + len(chunk) > LIMIT:
            raise HTTPException(413, "The recording exceeds 24 MiB.")
        audio.extend(chunk)
    if not audio:
        raise HTTPException(422, "The recording is empty.")
    return await transcribe_bytes(bytes(audio), kind)


async def transcribe_bytes(data: bytes, kind: str):
    key = setting("DEEPGRAM_API_KEY")
    data = await fetch_json("Deepgram", "POST", "https://api.deepgram.com/v1/listen",
                            params={"model": "nova-2", "diarize": "true", "utterances": "true", "punctuate": "true"},
                            headers={"Authorization": f"Token {key}", "Content-Type": kind},
                            content=data, timeout=180, limit=12_000_000)
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
    try:
        origin = urlsplit(ws.headers.get("origin", ""))
        return (ws.url.hostname in {"localhost", "127.0.0.1", "::1"}
                and origin.scheme == ("https" if ws.url.scheme == "wss" else "http")
                and origin.netloc == ws.headers.get("host"))
    except ValueError:
        return False


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
        key = setting("DEEPGRAM_API_KEY")
    except HTTPException:
        await ws.close(code=1008)
        return
    await ws.accept()
    try:
        if await asyncio.wait_for(ws.receive_text(), 10) != "send-audio-to-deepgram":
            await ws.close(code=1008)
            return
        url = "wss://api.deepgram.com/v1/listen?model=nova-2&punctuate=true"
        async with connect(url, additional_headers={"Authorization": f"Token {key}"}, open_timeout=10) as provider:
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
