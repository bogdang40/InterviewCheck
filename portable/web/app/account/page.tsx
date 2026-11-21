"use client"

import Link from "next/link"
import { useEffect } from "react"
import { ACCOUNT_EVENT } from "@/lib/useAccountStatus"
import Appearance from "@/components/Appearance"
import { AccountConnection } from "@/components/AccountConnection"
import WorkspaceError from "@/components/WorkspaceError"
import { useResource } from "@/lib/workspace"
import type { ProviderStatus } from "@/lib/integrations"

export default function AccountPage() {
  const status = useResource<ProviderStatus>("integrations/status")
  const reload = status.reload
  // Sign-in and sign-out change which view this page shows (public sign-in card or settings).
  useEffect(() => {
    window.addEventListener(ACCOUNT_EVENT, reload)
    return () => window.removeEventListener(ACCOUNT_EVENT, reload)
  }, [reload])
  if (status.data?.access && !status.data.signedIn) {
    // Shown inside the public sign-in frame (WorkspaceShell): the form only, no settings.
    return <div className="signin-card">
      <h1>Sign in</h1>
      <p>Open your interviews, roles and reports.</p>
      <AccountConnection enabled inviteRequired={status.data.inviteRequired} signedIn={false} variant="signin"/>
      <p className="signin-foot">No account yet? Workspaces are set up by invitation. Meanwhile, <Link href="/sample/">try the sample review</Link>.</p>
    </div>
  }
  return <div className="stack">
    <div className="page-title"><span className="eyebrow">ACCESS & APPEARANCE</span><h1>Account</h1></div>
    {status.error ? <WorkspaceError text={status.error} retry={status.reload}/> :
      status.data ? <AccountConnection enabled={status.data.access} inviteRequired={status.data.inviteRequired} signedIn={status.data.signedIn}/> :
      <section className="panel inset" role="status"><p className="muted">Loading account settings…</p></section>}
    <Appearance/>
  </div>
}
