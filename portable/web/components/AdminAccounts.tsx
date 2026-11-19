"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { integration } from "@/lib/integrations";

type Member = {
  user: { id: string; email: string; role: "user" | "admin"; disabled: boolean; complimentaryUntil: string | null };
  entitlement: { active: boolean; source: string };
};
type Audit = { id: number; at: string; action: string; targetUserId?: string };
type Page = { users: Member[]; nextCursor: string | null };

export function AdminAccounts() {
  const [query, setQuery] = useState("");
  const [page, setPage] = useState<Page>({ users: [], nextCursor: null });
  const [member, setMember] = useState<Member>();
  const [disabled, setDisabled] = useState(false);
  const [role, setRole] = useState<"admin" | "user">("user");
  const [grant, setGrant] = useState("");
  const [confirm, setConfirm] = useState(false);
  const [audit, setAudit] = useState<Audit[]>([]);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");

  async function load(cursor?: string) {
    const params = new URLSearchParams({ q: query });
    if (cursor) params.set("cursor", cursor);
    const result = await integration<Page>("admin/users?" + params.toString());
    setPage(previous => ({ users: cursor ? [...previous.users, ...result.users] : result.users, nextCursor: result.nextCursor }));
  }
  async function act(work: () => Promise<void>) {
    setBusy(true); setMessage("");
    try { await work(); } catch (error) { setMessage((error as Error).message); }
    finally { setBusy(false); }
  }
  function select(row: Member) {
    setMember(row); setDisabled(row.user.disabled); setRole(row.user.role); setConfirm(false);
    setGrant(row.user.complimentaryUntil?.slice(0, 10) || "");
  }
  async function save() {
    if (!member || !confirm) return;
    const updates: {role?: string; disabled?: boolean; complimentaryUntil?: string | null} = {};
    if (role !== member.user.role) updates.role = role;
    if (disabled !== member.user.disabled) updates.disabled = disabled;
    if (grant !== (member.user.complimentaryUntil?.slice(0, 10) || "")) {
      updates.complimentaryUntil = grant ? grant + "T23:59:59.999Z" : null;
    }
    if (!Object.keys(updates).length) { setMessage("No account changes to apply."); return; }
    const result = await integration<Member>("admin/users/" + member.user.id, { method: "PATCH",
      headers: { "Content-Type": "application/json" }, body: JSON.stringify(updates) });
    select(result); await load(); setMessage("Account updated.");
  }
  return <section className="stack"><h3>Manage accounts</h3>
    <form className="row align-end" onSubmit={event => { event.preventDefault(); void act(async () => { setMember(undefined); await load(); }); }}>
      <label className="field">Find accounts<Input value={query} onChange={e => setQuery(e.target.value)} placeholder="Email address" /></label>
      <Button disabled={busy} variant="outline">Search accounts</Button>
    </form>
    {page.users.length > 0 && <label className="field">Account to manage
      <select value={member?.user.id || ""} onChange={e => { const row = page.users.find(x => x.user.id === e.target.value); if (row) select(row); }}>
        <option value="">Select an account</option>{page.users.map(x => <option value={x.user.id} key={x.user.id}>{x.user.email}</option>)}
      </select></label>}
    {page.nextCursor && <Button variant="ghost" disabled={busy} onClick={() => act(() => load(page.nextCursor || undefined))}>More accounts</Button>}
    {member && <div className="stack">
      <p>{member.user.email} · {member.entitlement.active ? "Active" : "Inactive"} · {member.entitlement.source}</p>
      <label className="field">Account role<select value={role} onChange={e => { setConfirm(false); setRole(e.target.value as typeof role); }}>
        <option value="user">User</option><option value="admin">Administrator</option></select></label>
      <label className="field">Complimentary access through (UTC)<Input type="date" value={grant}
        onChange={e => { setConfirm(false); setGrant(e.target.value); }} /></label>
      <label className="check"><input type="checkbox" checked={disabled} onChange={e => { setConfirm(false); setDisabled(e.target.checked); }} /> Disable account and revoke sessions</label>
      <label className="check"><input type="checkbox" checked={confirm} onChange={e => setConfirm(e.target.checked)} /> Confirm changes for {member.user.email}</label>
      <div><Button disabled={busy || !confirm} onClick={() => act(save)}>Apply account changes</Button></div>
    </div>}
    <div><Button variant="outline" disabled={busy} onClick={() => act(async () => {
      const response = await integration<{entries: Audit[]}>("admin/audit"); setAudit(response.entries);
    })}>Recent account activity</Button></div>
    {audit.length > 0 && <ul>{audit.map(entry => <li key={entry.id}>{entry.at} · {entry.action}</li>)}</ul>}
    {message && <p role="status" className="notice">{message}</p>}
  </section>;
}
