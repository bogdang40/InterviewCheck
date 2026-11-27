"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useRef, useState } from "react";
import { ShieldCheck } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { AccountSecurityPanel } from "./AccountSecurityPanel";
import { AdminAccounts } from "./AdminAccounts";
import { PasswordChangeForm } from "./PasswordChangeForm";
import WorkspaceError from "./WorkspaceError";
import { message } from "@/lib/api";
import { sweepLocalDrafts } from "@/lib/localDraftSweep";
import { nextPathFromLocation } from "@/lib/safeNextPath";
import { integration, submit } from "@/lib/integrations";
import { submitAccessAuth } from "@/lib/totpApi";
import { notifyAccountChanged } from "@/lib/useAccountStatus";
import { readAccountSnapshot, type AccountSnapshot as Account } from "@/lib/accountSnapshot";



export function AccountConnection({
  enabled,
  inviteRequired,
  signedIn,
  variant = "settings",
}: {
  enabled: boolean;
  inviteRequired?: boolean;
  signedIn?: boolean;
  /** "signin": the public sign-in screen (no section heading; follows ?next= after sign-in). */
  variant?: "settings" | "signin";
}) {
  const router = useRouter();
  const [account, setAccount] = useState<Account | null>(null);
  // Set while the shell swaps between the public sign-in screen and the workspace, so the form or the
  // account controls are not shown (and typed into) just before they are replaced.
  const [leaving, setLeaving] = useState<"in" | "out" | null>(null);
  const [initializing, setInitializing] = useState(Boolean(enabled && signedIn !== false));
  const [initError, setInitError] = useState("");
  const [initSeq, setInitSeq] = useState(0);
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [totpCode, setTotpCode] = useState("");
  const [totpRequired, setTotpRequired] = useState(false);
  const [invite, setInvite] = useState("");
  const [plans, setPlans] = useState<string[]>([]);
  const [plansError, setPlansError] = useState("");
  const [plansSeq, setPlansSeq] = useState(0);
  const [adminSecret, setAdminSecret] = useState("");
  const [plan, setPlan] = useState("monthly");
  const [signup, setSignup] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const accountRead = useRef(0);
  const [rotating, setRotating] = useState(false);
  const refresh = useCallback(async (notify = true) => {
    const read = ++accountRead.current;
    const response = await fetch("/api/integrations/account", { cache: "no-store" }).catch(err => {
      if (read === accountRead.current) throw err;
      return null;
    });
    if (!response || read !== accountRead.current) return;
    if (response.status === 401) { setAccount(null); return; }
    const data = await response.json().catch(() => ({}));
    if (read !== accountRead.current) return;
    if (!response.ok) throw new Error(typeof data?.detail === "string" ? data.detail : "Could not load the account.");
    setAccount(readAccountSnapshot(data));
    if (notify) notifyAccountChanged("refresh");
  }, []);
  useEffect(() => {
    if (!enabled || signedIn === false) { setInitializing(false); setInitError(""); return; }
    let active = true;
    setInitializing(true);
    setInitError("");
    refresh()
      .catch(e => { if (active) setInitError(message(e)); })
      .finally(() => { if (active) setInitializing(false); });
    return () => { active = false; ++accountRead.current; };
  }, [enabled, signedIn, refresh, initSeq]);

  useEffect(() => {
    if (!account) { setPlansError(""); return; }
    let active = true;
    setPlansError("");
    integration<{ configured: boolean; plans: string[] }>("plans").then(data => {
      if (active) { setPlans(data.configured ? data.plans : []); setPlan(data.plans[0] || "monthly"); }
    }).catch(e => { if (active) setPlansError(message(e)); });
    return () => { active = false; };
  }, [account, plansSeq]);

  useEffect(() => {
    if (!leaving) return;
    // Normally the shell replaces this screen within a moment. If it does not, reload to settle.
    const timer = window.setTimeout(() => {
      const next = leaving === "in" ? nextPathFromLocation() : null;
      window.location.assign(next ?? window.location.pathname);
    }, 5000);
    return () => window.clearTimeout(timer);
  }, [leaving]);

  async function act(work: () => Promise<void>) {
    setBusy(true);
    setError("");
    try { await work(); } catch (e) { setError(message(e)); }
    finally { setBusy(false); }
  }
  async function billing(action: string) {
    const result = await submit<{ url: string }>("billing/" + action, action === "checkout" ? { plan } : {});
    window.location.assign(result.url);
  }
  if (leaving) return <section className="panel stack"><p role="status">
    {leaving === "in" ? "Signed in. Opening your workspace…" : "Signed out."}</p></section>;
  return <section className="panel stack">{variant === "settings" && <h2>Account and billing</h2>}
    {!enabled ? <p className="muted">Local workspace. Enable embedded accounts or configure a remote access service to sign in.</p> :
      initializing ? <p className="panel inset muted" role="status">Loading account status…</p> :
      initError ? <WorkspaceError text={initError} retry={() => setInitSeq(n => n + 1)} /> :
      account ? <>
        <p>{account.email} · {account.active ? "Access active" : "Subscription required"}</p>
        {plansError ? <WorkspaceError text={plansError} retry={() => setPlansSeq(n => n + 1)} /> :
          plans.length > 0 ? <div className="row align-end">
          <label className="field">Plan <select value={plan} onChange={e => setPlan(e.target.value)}>{plans.map(p => <option value={p} key={p}>{p === "annual" ? "Annual" : "Monthly"}</option>)}</select></label>
          <Button variant="outline" disabled={busy} onClick={() => act(() => billing("checkout"))}>Open checkout</Button>
          <Button variant="outline" disabled={busy} onClick={() => act(() => billing("portal"))}>Billing portal</Button>
        </div> : <p className="muted">Billing plans are unavailable.</p>}
        <div className="row">
          <Button variant="outline" disabled={busy || rotating} onClick={() => act(refresh)}>Refresh access</Button>
          <Button variant="ghost" disabled={busy} onClick={() => act(async () => { await submit("logout"); sweepLocalDrafts(); setLeaving("out"); setAccount(null); notifyAccountChanged(); })}>Sign out</Button>
        </div>
        <PasswordChangeForm
          onStart={() => {
            ++accountRead.current;
            setRotating(true);
          }}
          onRotated={next => {
            ++accountRead.current;
            setRotating(false);
            setAccount(next);
          }}
          onUnconfirmed={uncertain => {
            setRotating(false);
            const check = accountRead.current + 1;
            void refresh(false).catch(err => {
              if (check !== accountRead.current) return;
              if (uncertain) setAccount(null);
              setError(message(err));
            });
          }}
        />
        <AccountSecurityPanel
          isAdmin={Boolean(account.admin)}
          onCurrentSessionRevoked={() => {
            sweepLocalDrafts();
            setLeaving("out");
            setAccount(null);
            notifyAccountChanged();
          }}
        />
        {account.admin && <div className="panel inset spread">
          <div>
            <strong><ShieldCheck size={16} className="inline-icon" aria-hidden="true" /> Model and admin console</strong>
            <p className="muted">Configure connected AI models, probe provider endpoints, and review audit logs.</p>
          </div>
          <Button asChild size="sm">
            <Link href="/admin/">Open model admin panel</Link>
          </Button>
        </div>}
        {account.admin && <AdminAccounts />}
      </> : <form className="stack" onSubmit={e => { e.preventDefault(); void act(async () => {
        if (!signup && totpRequired && !totpCode.trim()) {
          throw new Error("Enter your 6-digit authenticator code or backup code.");
        }
        const res = await submitAccessAuth<Account>(signup ? "signup" : "login", {
          email,
          password,
          ...(!signup && totpRequired && totpCode.trim() ? { totpCode: totpCode.trim() } : {}),
          ...(signup && invite ? { inviteCode: invite } : {}),
          ...(signup && adminSecret ? { adminSecret } : {}),
        });
        if (!res.ok) {
          setTotpRequired(true);
          setTotpCode("");
          return;
        }
        setPassword(""); setTotpCode(""); setTotpRequired(false); setInvite(""); setAdminSecret("");
        if (variant === "signin") {
          // The shell swaps this screen for the workspace once its status refreshes; until then
          // show a status, not account controls that are about to be replaced.
          setLeaving("in");
          notifyAccountChanged();
          const next = nextPathFromLocation();
          if (next) router.push(next);
          return;
        }
        setAccount(res.account);
        notifyAccountChanged();
      }); }}>
        <label className="field">Operator email<Input type="email" autoComplete="username" required value={email} onChange={e => {
          setEmail(e.target.value);
          if (totpRequired) { setTotpRequired(false); setTotpCode(""); }
        }} /></label>
        <label className="field">Password<Input type="password" minLength={10} required autoComplete={signup ? "new-password" : "current-password"}
          value={password} onChange={e => setPassword(e.target.value)} /></label>
        {!signup && totpRequired && (
          <div className="panel inset stack">
            <p role="status" className="notice">Two-factor authentication is required. Enter a 6-digit authenticator code or a single-use backup code.</p>
            <label className="field">Authenticator or backup code
              <Input type="text" autoComplete="one-time-code" required placeholder="123456 or XXXX-XXXX" value={totpCode} onChange={e => setTotpCode(e.target.value)} />
            </label>
          </div>
        )}
        {signup && inviteRequired && <label className="field">Invitation code<Input type="password" required
          autoComplete="off" value={invite} onChange={e => setInvite(e.target.value)} /></label>}
        {signup && <details><summary>Administrator setup</summary><label className="field">Bootstrap secret<Input type="password"
          autoComplete="off" value={adminSecret} onChange={e => setAdminSecret(e.target.value)} /></label></details>}
        <div className="row"><Button disabled={busy}>{signup ? "Create account" : totpRequired ? "Verify and sign in" : "Sign in"}</Button>
          <Button type="button" variant="ghost" onClick={() => { setSignup(!signup); setTotpRequired(false); setTotpCode(""); setError(""); }}>{signup ? "Use existing account" : "Create an account"}</Button></div>
      </form>}
    {error && <p role="alert" className="error">{error}</p>}
  </section>;
}
