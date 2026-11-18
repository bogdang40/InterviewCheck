"use client"

import Roles from "@/components/Roles"
import Migration from "@/components/Migration"
import WorkspaceError from "@/components/WorkspaceError"
import { usePreparation, useResource } from "@/lib/workspace"
import type { Role } from "@/lib/api"

export default function RolesPage() {
  const roles = useResource<Role[]>("roles")
  const { prepare } = usePreparation()
  if (roles.error) return <WorkspaceError text={roles.error} retry={roles.reload} />
  if (!roles.data) return <p role="status">Loading role library…</p>
  return (
    <div className="stack">
      <Roles
        roles={roles.data}
        onSave={(role) => roles.update((old) => [role, ...old.filter((r) => r.id !== role.id)])}
        prepare={(r) => prepare({ candidate: "", role: r.name, roleId: r.id })}
      />
      <Migration onImported={roles.reload} />
    </div>
  )
}
