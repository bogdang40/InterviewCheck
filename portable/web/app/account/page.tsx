"use client"

import Link from "next/link"
import { useContext } from "react"
import Appearance from "@/components/Appearance"
import { AccountConnection } from "@/components/AccountConnection"
import WorkspaceError from "@/components/WorkspaceError"
import { SignInScreenContext, useResource } from "@/lib/workspace"
import type { ProviderStatus } from "@/lib/integrations"

export default function AccountPage() {
  const status = useResource<ProviderStatus>("integrations/status")
  // WorkspaceShell decides (one switch, from its own status) whether this is the public sign-in screen.
  const signInScreen = useContext(SignInScreenContext)
  if (signInScreen) {
    // Shown inside the public sign-in frame (WorkspaceShell): the form only, no settings.
    return <div className="signin-card">
      <h1>Sign in</h1>
      <p>Open your interviews, roles and reports.</p>
      <AccountConnection enabled inviteRequired={status.data?.inviteRequired} signedIn={false} variant="signin"/>
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
