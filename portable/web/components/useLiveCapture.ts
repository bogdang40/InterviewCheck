"use client";

import { useEffect, useRef, useState } from "react";

type CaptureState = "idle" | "connecting" | "recording" | "finishing";
type Source = "call" | "microphone";

export function useLiveCapture(onText: (text: string) => void, onError: (error: string) => void) {
  const [state, setState] = useState<CaptureState>("idle");
  const phase = useRef<CaptureState>("idle");
  function transition(next: CaptureState) {
    phase.current = next;
    setState(next);
  }
  const generation = useRef(0);
  const capture = useRef<MediaStream | null>(null);
  const socket = useRef<WebSocket | null>(null);
  const recorder = useRef<MediaRecorder | null>(null);
  const watchdog = useRef<number | undefined>(undefined);

  function release() {
    window.clearTimeout(watchdog.current);
    const active = recorder.current;
    recorder.current = null;
    if (active && active.state !== "inactive") active.stop();
    capture.current?.getTracks().forEach(track => track.stop());
    capture.current = null;
    const connection = socket.current;
    socket.current = null;
    if (connection && connection.readyState < WebSocket.CLOSING) connection.close();
  }

  useEffect(() => () => { generation.current++; release(); }, []);

  function waitForTail() {
    transition("finishing");
    window.clearTimeout(watchdog.current);
    watchdog.current = window.setTimeout(() => {
      generation.current++;
      release();
      transition("idle");
      onError("Timed out waiting for the final transcript. Review the captured excerpt.");
    }, 15000);
  }

  function finish() {
    if (phase.current === "finishing" || phase.current === "idle") return;
    if (phase.current === "recording") {
      waitForTail();
      if (recorder.current?.state === "recording") recorder.current.stop();
    } else {
      generation.current++;
      release();
      transition("idle");
    }
  }

  async function start(source: Source) {
    const current = ++generation.current;
    release();
    transition("connecting");
    const fail = (message: string) => {
      if (generation.current !== current) return;
      generation.current++;
      release();
      transition("idle");
      onError(message);
    };
    try {
      if (!navigator.mediaDevices || typeof MediaRecorder === "undefined") {
        throw new Error("This browser cannot record audio. Import a recording or enter the answer.");
      }
      if (source === "call" && !navigator.mediaDevices.getDisplayMedia) {
        throw new Error("This browser cannot share call audio. Select the microphone or import a recording.");
      }
      const stream = source === "call"
        ? await navigator.mediaDevices.getDisplayMedia({ video: true, audio: true })
        : await navigator.mediaDevices.getUserMedia({ audio: true });
      if (generation.current !== current) {
        stream.getTracks().forEach(track => track.stop());
        return;
      }
      capture.current = stream;
      const tracks = stream.getAudioTracks();
      if (!tracks.length) throw new Error("No call audio was shared. Select a tab and enable audio in the browser picker.");
      // Display capture needs a video track for selection. Only audio enters the recorder.
      const mimeType = ["audio/webm;codecs=opus", "audio/ogg;codecs=opus", "audio/mp4"].find(type => MediaRecorder.isTypeSupported(type));
      if (!mimeType) throw new Error("This browser cannot encode a supported audio format.");
      const recording = new MediaRecorder(new MediaStream(tracks), { mimeType });
      recorder.current = recording;
      const protocol = location.protocol === "https:" ? "wss:" : "ws:";
      const connection = new WebSocket(protocol + "//" + location.host + "/api/integrations/live");
      socket.current = connection;
      watchdog.current = window.setTimeout(() => fail("The transcription connection timed out."), 20000);
      connection.onopen = () => connection.send("send-audio-to-deepgram");
      connection.onmessage = event => {
        if (generation.current !== current) return;
        try {
          const message = JSON.parse(event.data);
          if (message.error) return fail(message.error);
          if (message.ready) {
            window.clearTimeout(watchdog.current);
            recording.start(300);
            transition("recording");
          }
          if (typeof message.text === "string") onText(message.text);
        } catch { fail("The transcription service returned an invalid message."); }
      };
      recording.ondataavailable = event => {
        if (!event.data.size || connection.readyState !== WebSocket.OPEN) return;
        if (connection.bufferedAmount > 1024 * 1024) return fail("The connection is too slow for live audio.");
        connection.send(event.data);
      };
      recording.onstop = () => {
        if (generation.current !== current) return;
        if (phase.current !== "finishing") waitForTail();
        stream.getTracks().forEach(track => track.stop());
        if (connection.readyState === WebSocket.OPEN) connection.send("finish");
      };
      recording.onerror = () => fail("The browser stopped recording.");
      stream.getTracks().forEach(track => track.addEventListener("ended", finish, { once: true }));
      connection.onerror = () => fail("Could not open the live transcription connection. Check your account and Deepgram key.");
      connection.onclose = event => {
        if (generation.current !== current) return;
        if (event.code !== 1000) return fail("The transcription connection closed early.");
        generation.current++;
        release();
        transition("idle");
      };
    } catch (error) {
      fail(error instanceof Error ? error.message : "Could not start audio capture.");
    }
  }
  return { state, start, finish };
}
