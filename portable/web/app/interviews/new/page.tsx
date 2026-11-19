"use client"

import { useRouter } from "next/navigation"
import SessionSetup from "@/components/SessionSetup"
import WorkspaceError from "@/components/WorkspaceError"
import { useResource, usePreparation, interviewURL } from "@/lib/workspace"
import type { Role } from "@/lib/api"

export default function NewInterviewPage() {
  const router = useRouter()
  const { preparation } = usePreparation()
  const roles = useResource<Role[]>("roles")
  if (roles.error) return <WorkspaceError text={roles.error} retry={roles.reload} />
  if (!roles.data) return <section className="panel inset" role="status"><p className="muted">Loading setup…</p></section>
  return <SessionSetup roles={roles.data} {...preparation}
    onRoleLoad={role => roles.update(list => list.map(item => item.id === role.id ? role : item))}
    onStart={(s) => router.push(interviewURL(s.id))} />
}
