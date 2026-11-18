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
  if (!roles.data) return <p role="status">Loading setup…</p>
  return <SessionSetup roles={roles.data} {...preparation} onStart={(s) => router.push(interviewURL(s.id))} />
}
