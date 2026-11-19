"use client"

import Link from "next/link"
import { useSearchParams } from "next/navigation"
import { Suspense, useEffect, useRef } from "react"
import { Button } from "@/components/ui/button"
import Roles from "@/components/Roles"
import Migration from "@/components/Migration"
import WorkspaceError from "@/components/WorkspaceError"
import { usePreparation, useResource } from "@/lib/workspace"
import type { Role } from "@/lib/api"

function RoleLibrary() {
  const id = useSearchParams().get("role")
  const list = useResource<Role[]>(id ? null : "roles")
  const item = useResource<Role>(id ? "roles/" + encodeURIComponent(id) : null)
  const { prepare } = usePreparation()
  const heading = useRef<HTMLHeadingElement>(null)
  useEffect(() => { if (item.data) heading.current?.focus() }, [item.data?.id])
  const error = id ? item.error : list.error
  if (error) return <WorkspaceError text={error} retry={id ? item.reload : list.reload}/>
  if (id && item.data) {
    const role = item.data
    return <div className="stack">
      <Link href="/roles/" className="text-action">All roles</Link>
      <header className="page-title"><h1 ref={heading} tabIndex={-1}>{role.name}</h1><p>{role.description}</p></header>
      <section className="panel stack"><h2>Interview plan</h2><p>{role.policy || "No assistance policy saved."}</p>
        {role.questions.length > 0 && <ol>{role.questions.map((question, i) => <li key={i}>{i + 1}. {question}</li>)}</ol>}
        {role.permitted_sources.map((source, i) => <details key={i}><summary>{source.label}</summary><p>{source.text}</p></details>)}
        <div><Button onClick={() => prepare({ candidate: "", role: role.name, roleId: role.id })}>Prepare interview</Button></div>
      </section>
    </div>
  }
  if (!list.data) return <section className="panel inset" role="status"><p className="muted">Loading role library…</p></section>
  return <div className="stack">
    <Roles roles={list.data} onSave={role => list.update(old => [role, ...old.filter(row => row.id !== role.id)])}
      prepare={role => prepare({ candidate: "", role: role.name, roleId: role.id })}/>
    <Migration onImported={list.reload}/>
  </div>
}

export default function RolesPage() {
  return <Suspense fallback={<section className="panel inset" role="status"><p className="muted">Loading role library…</p></section>}><RoleLibrary/></Suspense>
}
