"use client";

import { useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { integration } from "@/lib/integrations";
import { readCues } from "@/lib/transcript";

export type Segment = { speaker: string; text: string };
type Recording = { id: string; title: string; start: string; kind: string };
type Files = { items: Recording[]; note?: string };

export function MeetingRecordings({ providers, enabled, receive, onBusy }: {
  providers: string[]; enabled: boolean; receive: (segments: Segment[]) => void; onBusy: (busy: boolean) => void;
}) {
  const [files, setFiles] = useState<Files | null>(null);
  const [selected, setSelected] = useState<Recording | undefined>();
  const [send, setSend] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const abort = useRef<AbortController | null>(null);
  useEffect(() => () => { abort.current?.abort(); onBusy(false); }, [onBusy]);
  if (!providers.length) return null;
  function post<T>(path: string, data?: object) {
    return integration<T>(path, { method: "POST", signal: abort.current?.signal,
      headers: {"Content-Type": "application/json"}, body: data ? JSON.stringify(data) : undefined });
  }
  async function run(work: () => Promise<void>) {
    abort.current = new AbortController();
    setError(""); setBusy(true); onBusy(true);
    try { await work(); } catch (e) { setError((e as Error).message); }
    finally { setBusy(false); onBusy(false); }
  }
  const media = !!selected && !["transcript", "meeting"].includes(selected.kind);
  const vendors: Record<string,string> = {zoom: "Zoom", webex: "Webex", meet: "Google Meet", teams: "Teams"};
  return <div className="stack"><strong>Meeting recordings</strong>
    <div className="row">{providers.map(name => <Button key={name} type="button" variant="outline" disabled={busy}
      onClick={() => run(async () => {
        setSelected(undefined); setFiles(null); setSend(false);
        setFiles(await post<Files>("recordings/" + name));
      })}>List {vendors[name]} files</Button>)}</div>
    {files && (files.items.length ? <label className="field">Recent recordings and transcripts
      <select disabled={busy} value={selected?.id || ""} onChange={e => { setSelected(files.items.find(f => f.id === e.target.value)); setSend(false); }}>
        <option value="">Select a file</option>{files.items.map(f => <option key={f.id} value={f.id}>{f.start.slice(0,10)} · {f.title} · {f.kind}</option>)}
      </select></label> : <p>No files returned for the last 30 days.</p>)}
    {files?.note && <p className="muted">{files.note}</p>}
    {selected && <>
      {media && <label><input type="checkbox" checked={send} disabled={!enabled || busy}
        onChange={e => setSend(e.target.checked)} /> {enabled ? "Participants agreed to send this recording to Deepgram." : "Transcription is not configured on the server."}</label>}
      <Button variant="outline" type="button" disabled={busy || (media && !send)}
        onClick={() => run(async () => {
          const result = await post<{ vtt?: string; segments?: Segment[]; items?: Recording[]; note?: string }>("recording/" + selected.id, { send_to_deepgram: send });
          if (result.items) {
            setFiles({items: result.items, note: result.note}); setSelected(undefined); setSend(false); return;
          }
          receive(result.vtt ? readCues(result.vtt) : result.segments || []);
        })}>{selected.kind === "meeting" ? "List files for this meeting" : selected.kind === "transcript" ? "Import saved transcript" : "Send recording to Deepgram"}</Button>
    </>}
    {busy && <p role="status">Reading meeting file…</p>}
    {error && <p role="alert" className="notice">{error}</p>}
  </div>;
}
