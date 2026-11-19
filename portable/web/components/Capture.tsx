"use client";

import { useEffect, useRef, useState } from "react";
import { AudioLines, Square, Upload } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { integration, type ProviderStatus } from "@/lib/integrations";
import { RecordingExcerpt } from "./RecordingExcerpt";
import { MeetingRecordings, type Segment } from "./MeetingRecordings";
import { useLiveCapture } from "./useLiveCapture";

const extensions: Record<string, string> = { wav: "audio/wav", m4a: "audio/mp4", mp3: "audio/mpeg",
  webm: "audio/webm", ogg: "audio/ogg", oga: "audio/ogg", flac: "audio/flac", mp4: "video/mp4", mov: "video/quicktime" };


export default function Capture({ onText, onPendingChange }: {
  onText: (text: string) => void;
  onPendingChange?: (pending: boolean) => void;
}) {
  const [providers, setProviders] = useState<ProviderStatus>();
  const enabled = !!providers?.transcription;
  const [fileVersion, setFileVersion] = useState(0);
  const [consent, setConsent] = useState(false);
  const [source, setSource] = useState<"microphone" | "call">("call");
  const [file, setFile] = useState<File | null>(null);
  const [segments, setSegments] = useState<Segment[]>([]);
  const [draft, setDraft] = useState("");
  const [uploading, setUploading] = useState(false);
  const [remoteBusy, setRemoteBusy] = useState(false);
  const abortUpload = useRef<AbortController | null>(null);
  useEffect(() => () => abortUpload.current?.abort(), []);
  const [error, setError] = useState("");
  const live = useLiveCapture(text => setDraft(old => [old, text].filter(Boolean).join(" ")), setError);
  const active = live.state !== "idle";
  const pending = active || uploading || remoteBusy || segments.length > 0 || !!draft.trim();
  useEffect(() => { onPendingChange?.(pending); }, [onPendingChange, pending]);
  useEffect(() => {
    const abort = new AbortController();
    integration<ProviderStatus>("status", { signal: abort.signal })
      .then(setProviders)
      .catch(error => { if (!abort.signal.aborted) setError(error.message); });
    return () => abort.abort();
  }, []);

  async function upload() {
    if (!file || !consent || uploading) return;
    setError("");
    if (file.size > 24 * 1024 * 1024) return setError("Choose a file up to 24 MiB.");
    const controller = new AbortController();
    abortUpload.current = controller;
    setUploading(true);
    try {
      const result = await integration<{ segments: Segment[] }>("transcribe", {
        method: "POST",
        headers: { "Content-Type": extensions[file.name.split(".").pop()?.toLowerCase() || ""] || file.type || "application/octet-stream", "X-Send-Audio": "deepgram" },
        body: file, signal: controller.signal,
      });
      if (!controller.signal.aborted) receive(result.segments);
    } catch (e) { if (!controller.signal.aborted) setError((e as Error).message); }
    finally { if (!controller.signal.aborted) setUploading(false); }
  }

  function receive(items: Segment[]) {
    setSegments(items); setDraft(""); setFileVersion(value => value + 1);
  }

  return <details className="capture-tools">
    <summary><AudioLines size={16} aria-hidden /> Capture audio</summary>
    <div className="stack">
      {error && <p role="alert" className="notice">{error}</p>}
      {!enabled ? <p className="muted">Configure an enabled transcription model in Admin or server settings to transcribe call audio or a recording.</p> : <>
        <label><input type="checkbox" checked={consent} disabled={active || uploading}
          onChange={event => setConsent(event.target.checked)} /> Participants agreed to send this audio to Deepgram.</label>
        <div className="row">
          <label className="field">Audio source
            <select value={source} disabled={active} onChange={event => setSource(event.target.value as typeof source)}>
              <option value="call">Shared call tab or system audio</option><option value="microphone">Microphone</option>
            </select>
          </label>
          {active ? <Button type="button" variant="outline" disabled={live.state === "finishing"} onClick={live.finish}>
            <Square /> {live.state === "connecting" ? "Cancel" : live.state === "finishing" ? "Finishing" : "Stop capture"}
          </Button> : <Button type="button" variant="outline" disabled={!consent || uploading || remoteBusy || !!draft || segments.length > 0}
            onClick={() => { setError(""); void live.start(source); }}><AudioLines /> Start transcription</Button>}
        </div>
        <label className="field">Recorded audio or video
          <input type="file" accept="audio/*,video/mp4,video/webm,video/quicktime" disabled={uploading || remoteBusy || active || !!draft || segments.length > 0}
            onChange={event => { setFile(event.target.files?.[0] ?? null); }} />
        </label>
        <Button type="button" variant="outline" disabled={!file || !consent || uploading || remoteBusy || active || !!draft || segments.length > 0}
          onClick={upload}><Upload /> {uploading ? "Transcribing" : "Send recording to Deepgram"}</Button>
      </>}
      {!active && !uploading && !draft && !segments.length && <MeetingRecordings providers={providers?.meetings || []} enabled={enabled} receive={receive} onBusy={setRemoteBusy} />}
      {segments.length > 0 && <RecordingExcerpt key={fileVersion} segments={segments}
        onApply={text => { onText(text); setSegments([]); }}
        onDiscard={() => setSegments([])} />}
        {(draft || active) && <>
          <label className="field">Candidate excerpt<Textarea rows={4} value={draft} onChange={event => setDraft(event.target.value)} /></label>
          <Button type="button" variant="outline" disabled={active || !draft.trim()}
            onClick={() => { onText(draft.trim()); setDraft(""); setSegments([]); }}>Use this excerpt</Button>
          <Button type="button" variant="ghost" disabled={active || uploading || remoteBusy}
            onClick={() => { setDraft(""); setSegments([]); }}>Discard excerpt</Button>
        </>}
    </div>
  </details>;
}
