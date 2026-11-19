"use client"

import Appearance from "@/components/Appearance"
import { AccountConnection } from "@/components/AccountConnection"
import WorkspaceError from "@/components/WorkspaceError"
import { useResource } from "@/lib/workspace"
import type { ProviderStatus } from "@/lib/integrations"

export default function AccountPage() {
  const status = useResource<ProviderStatus>("integrations/status")
  return <div className="stack">
    <div className="page-title"><span className="eyebrow">ACCESS & APPEARANCE</span><h1>Account</h1></div>
    {status.error ? <WorkspaceError text={status.error} retry={status.reload}/> :
      status.data ? <AccountConnection enabled={status.data.access} inviteRequired={status.data.inviteRequired} signedIn={status.data.signedIn}/> :
      <section className="panel inset" role="status"><p className="muted">Loading account settings…</p></section>}
    <Appearance/>
  </div>
}
