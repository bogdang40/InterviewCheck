"use client";

import { useCallback, useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { submit } from "@/lib/integrations";

type Account = { email: string; active: boolean };

export function AccountConnection({ enabled }: { enabled: boolean }) {
  const [account, setAccount] = useState<Account | null>(null);
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
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
    {!enabled ? <p className="muted">Local workspace. Set INTERVIEWCHECK_ACCESS_URL and INTERVIEWCHECK_OPERATOR_EMAIL to use the access server.</p> :
      account ? <>
        <p>{account.email} · {account.active ? "Access active" : "Subscription required"}</p>
        <div className="row">
          <label>Plan <select value={plan} onChange={e => setPlan(e.target.value)}><option value="monthly">Monthly</option><option value="annual">Annual</option></select></label>
          <Button variant="outline" disabled={busy} onClick={() => act(() => billing("checkout"))}>Open checkout</Button>
          <Button variant="outline" disabled={busy} onClick={() => act(() => billing("portal"))}>Billing portal</Button>
        </div>
        <div className="row">
          <Button variant="outline" disabled={busy} onClick={() => act(refresh)}>Refresh access</Button>
          <Button variant="ghost" disabled={busy} onClick={() => act(async () => { await submit("logout"); setAccount(null); })}>Sign out</Button>
        </div>
      </> : <form className="stack" onSubmit={e => { e.preventDefault(); void act(async () => {
        setAccount(await submit<Account>("access/" + (signup ? "signup" : "login"), { email, password }));
        setPassword("");
      }); }}>
        <label className="field">Operator email<Input type="email" autoComplete="username" required value={email} onChange={e => setEmail(e.target.value)} /></label>
        <label className="field">Password<Input type="password" minLength={10} required autoComplete={signup ? "new-password" : "current-password"}
          value={password} onChange={e => setPassword(e.target.value)} /></label>
        <div className="row"><Button disabled={busy}>{signup ? "Create account" : "Sign in"}</Button>
          <Button type="button" variant="ghost" onClick={() => setSignup(!signup)}>{signup ? "Use existing account" : "Create an account"}</Button></div>
      </form>}
    {error && <p role="alert" className="notice">{error}</p>}
  </section>;
}
