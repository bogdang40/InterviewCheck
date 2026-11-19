"use client";

import AudioPreflight from "./AudioPreflight"
import { useEffect, useState } from "react";
import { CalendarDays, ContactRound, RefreshCw } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { integration, submit, type ProviderStatus } from "@/lib/integrations";
import Link from "next/link";
import ConnectionCatalog from "./ConnectionCatalog";

type Row = { booking_id?: string; title?: string; start?: string; candidate: string; role: string };
type Results = { items: Row[]; note?: string };
const names: Record<string, string> = { imap: "Mailbox invites", workable: "Workable", teamtailor: "Teamtailor", smartrecruiters: "SmartRecruiters",
  bamboohr: "BambooHR", recruitee: "Recruitee", personio: "Personio", jobadder: "JobAdder", kombo: "Kombo", unified: "Unified.to",
  zoom: "Zoom", webex: "Webex", calendly: "Calendly", calcom: "Cal.com", google: "Google Calendar", microsoft: "Microsoft 365", ashby: "Ashby",
  lever: "Lever", merge: "Merge", greenhouse: "Greenhouse" };

export default function Connections({ onPrepare }: { onPrepare: (candidate: string, role: string) => void }) {
  const [status, setStatus] = useState<ProviderStatus>();
  const [records, setRecords] = useState<Results | null>(null);
  const [selected, setSelected] = useState<Row | null>(null);
  const [email, setEmail] = useState("");
  const [ats, setAts] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  useEffect(() => {
    const controller = new AbortController();
    integration<ProviderStatus>("status", { signal: controller.signal }).then(result => {
      setStatus(result); setAts(result.ats?.[0] || "");
    }).catch(e => { if (!controller.signal.aborted) setError(e.message); });
    return () => controller.abort();
  }, []);

  async function load(work: () => Promise<Results>) {
    setBusy(true);
    setError("");
    setSelected(null);
    setRecords(null);
    try { setRecords(await work()); } catch (e) { setError((e as Error).message); }
    finally { setBusy(false); }
  }
  function readFile(file?: File, path?: string) {
    if (file) void load(async () => {
      if (file.size > 500000) throw new Error("Choose a file under 500 KB.");
      return await submit<Results>(path + "/file", { text: await file.text() });
    });
  }
  async function selectRow(row: Row) {
    setSelected({ ...row });
    if (!row.booking_id) return;
    setBusy(true); setError("");
    try {
      const data = await submit<{ candidate: string }>("calendar/calendly/" + row.booking_id);
      setSelected({ ...row, candidate: data.candidate });
    } catch (e) { setError((e as Error).message); }
    finally { setBusy(false); }
  }
  return <div className="stack">
    <ConnectionCatalog/>
    <section id="connection-import" className="panel stack"><h2><CalendarDays aria-hidden size={18} /> Calendar</h2>
      <label className="field">Import calendar events
        <input type="file" accept=".ics,text/calendar" disabled={busy}
          onChange={e => { readFile(e.target.files?.[0], "calendar"); e.target.value = ""; }} /></label>
      {status && ((status.calendars?.length ?? 0) > 0 ? <div className="row">{(status.calendars ?? []).map(source =>
        <Button key={source} variant="outline" disabled={busy} onClick={() => load(() => submit("calendar/sync/" + source))}>
          <RefreshCw /> Sync {names[source]}</Button>)}</div> :
        <p className="muted">Connect Google Calendar or Microsoft 365 with a server access token, or select an .ics file.</p>)}
    </section>
    <section className="panel stack"><h2><ContactRound aria-hidden size={18} /> Applicant tracking</h2>
      <label className="field">Import candidates from CSV
        <input type="file" accept=".csv,text/csv" disabled={busy}
          onChange={e => { readFile(e.target.files?.[0], "ats"); e.target.value = ""; }} /></label>
      <p className="muted">Use candidate and role as the column headers.</p>
      {status && ((status.ats?.length ?? 0) > 0 ? <form className="row" onSubmit={e => {
        e.preventDefault(); void load(() => submit("ats/" + ats + "/lookup", { email }));
      }}>
        <label className="field">ATS<select value={ats} onChange={e => setAts(e.target.value)}>
          {(status.ats ?? []).map(source => <option key={source} value={source}>{names[source]}</option>)}</select></label>
        <label className="field">Candidate email<Input type="email" required value={email} onChange={e => setEmail(e.target.value)} /></label>
        <Button variant="outline" disabled={busy}>Find candidate</Button>
      </form> : <p className="muted">Configure a supported ATS on the server for candidate lookup.</p>)}
    </section>
    {error && <p className="notice" role="alert">{error}</p>}
    {busy && <p role="status">Reading records…</p>}
    {records && <section className="panel stack"><h2>Imported records</h2>
      {records.note && <p className="muted">{records.note}</p>}
      {records.items.length === 0 && <p>No records found.</p>}
      {records.items.map((row, index) => <div className="row" key={index}>
        <div><strong>{row.title || row.candidate}</strong>{(row.start || row.role) && <p className="muted">{row.start || row.role}</p>}</div>
        <Button variant="outline" disabled={busy} onClick={() => selectRow(row)}>Select</Button>
      </div>)}</section>}
    {selected && <form className="panel stack" onSubmit={e => { e.preventDefault(); onPrepare(selected.candidate.trim(), selected.role.trim()); }}>
      <h2>Prepare interview</h2>{selected.title && <p>{selected.title}</p>}
      <label className="field">Candidate<Input required disabled={busy} value={selected.candidate} onChange={e => setSelected({ ...selected, candidate: e.target.value })} /></label>
      <label className="field">Role<Input required disabled={busy} value={selected.role} onChange={e => setSelected({ ...selected, role: e.target.value })} /></label>
      <Button>Prepare interview</Button>
    </form>}
    <Link className="text-action" href="/account/">Account and billing settings</Link>
    <AudioPreflight />
  </div>;
}
