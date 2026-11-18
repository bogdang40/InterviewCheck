"use client"

import Appearance from "@/components/Appearance"
import { AccountConnection } from "@/components/AccountConnection"
import WorkspaceError from "@/components/WorkspaceError"
import { useResource } from "@/lib/workspace"
import type { ProviderStatus } from "@/lib/integrations"

export default function AccountPage() {
  const status = useResource<ProviderStatus>("integrations/status")
  return <div className="stack">
    <div className="page-title"><h1>Account</h1></div>
    {status.error ? <WorkspaceError text={status.error} retry={status.reload}/> :
      status.data ? <AccountConnection enabled={status.data.access} inviteRequired={status.data.inviteRequired}/> :
      <p role="status">Loading account settings…</p>}
    <Appearance/>
  </div>
}
