"use client";

import { useCallback, useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { AdminAccounts } from "./AdminAccounts";
import { integration, submit } from "@/lib/integrations";

type Account = { email: string; active: boolean; admin?: boolean };

export function AccountConnection({ enabled, inviteRequired }: { enabled: boolean; inviteRequired?: boolean }) {
  const [account, setAccount] = useState<Account | null>(null);
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [invite, setInvite] = useState("");
  const [plans, setPlans] = useState<string[]>([]);
  const [adminSecret, setAdminSecret] = useState("");
  const [plan, setPlan] = useState("monthly");
  const [signup, setSignup] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const refresh = useCallback(async () => {
    const response = await fetch("/api/integrations/account", { cache: "no-store" });
    if (response.status === 401) { setAccount(null); return; }
    const data = await response.json();
    if (!response.ok) throw new Error(data.detail || "Could not load the account.");
    setAccount(data as Account);
  }, []);
  useEffect(() => {
    if (enabled) void refresh().catch(e => setError(e.message));
  }, [enabled, refresh]);

  useEffect(() => {
    if (!account) return;
    let active = true;
    integration<{ configured: boolean; plans: string[] }>("plans").then(data => {
      if (active) { setPlans(data.configured ? data.plans : []); setPlan(data.plans[0] || "monthly"); }
    }).catch(e => { if (active) setError(e.message); });
    return () => { active = false; };
  }, [account]);

  async function act(work: () => Promise<void>) {
    setBusy(true);
    setError("");
    try { await work(); } catch (e) { setError((e as Error).message); }
    finally { setBusy(false); }
  }
  async function billing(action: string) {
    const result = await submit<{ url: string }>("billing/" + action, action === "checkout" ? { plan } : {});
    window.location.assign(result.url);
  }
  return <section className="panel stack"><h2>Account and billing</h2>
    {!enabled ? <p className="muted">Local workspace. Enable embedded accounts or configure a remote access service to sign in.</p> :
      account ? <>
        <p>{account.email} · {account.active ? "Access active" : "Subscription required"}</p>
        {plans.length > 0 ? <div className="row">
          <label>Plan <select value={plan} onChange={e => setPlan(e.target.value)}>{plans.map(p => <option value={p} key={p}>{p === "annual" ? "Annual" : "Monthly"}</option>)}</select></label>
          <Button variant="outline" disabled={busy} onClick={() => act(() => billing("checkout"))}>Open checkout</Button>
          <Button variant="outline" disabled={busy} onClick={() => act(() => billing("portal"))}>Billing portal</Button>
        </div> : <p className="muted">Billing plans are unavailable.</p>}
        <div className="row">
          <Button variant="outline" disabled={busy} onClick={() => act(refresh)}>Refresh access</Button>
          <Button variant="ghost" disabled={busy} onClick={() => act(async () => { await submit("logout"); setAccount(null); })}>Sign out</Button>
        </div>
        {account.admin && <AdminAccounts />}
      </> : <form className="stack" onSubmit={e => { e.preventDefault(); void act(async () => {
        setAccount(await submit<Account>("access/" + (signup ? "signup" : "login"), { email, password, ...(signup && invite ? {inviteCode: invite} : {}), ...(signup && adminSecret ? {adminSecret} : {}) }));
        setPassword(""); setInvite(""); setAdminSecret("");
      }); }}>
        <label className="field">Operator email<Input type="email" autoComplete="username" required value={email} onChange={e => setEmail(e.target.value)} /></label>
        <label className="field">Password<Input type="password" minLength={10} required autoComplete={signup ? "new-password" : "current-password"}
          value={password} onChange={e => setPassword(e.target.value)} /></label>
        {signup && inviteRequired && <label className="field">Invitation code<Input type="password" required
          autoComplete="off" value={invite} onChange={e => setInvite(e.target.value)} /></label>}
        {signup && <details><summary>Administrator setup</summary><label className="field">Bootstrap secret<Input type="password"
          autoComplete="off" value={adminSecret} onChange={e => setAdminSecret(e.target.value)} /></label></details>}
        <div className="row"><Button disabled={busy}>{signup ? "Create account" : "Sign in"}</Button>
          <Button type="button" variant="ghost" onClick={() => setSignup(!signup)}>{signup ? "Use existing account" : "Create an account"}</Button></div>
      </form>}
    {error && <p role="alert" className="notice">{error}</p>}
  </section>;
}
