"use client"

import dynamic from "next/dynamic"
import Link from "next/link"
import { useSearchParams } from "next/navigation"
import { Suspense, useEffect, useRef, useState } from "react"
import { Button } from "@/components/ui/button"
import Roles from "@/components/Roles"
import RoleVersionHistory from "@/components/RoleVersionHistory"
import Migration from "@/components/Migration"
import WorkspaceError from "@/components/WorkspaceError"
import { usePreparation, useResource } from "@/lib/workspace"
import type { CalibratedRole } from "@/lib/roleCalibration"

const CalibrationQueuePanel = dynamic(() => import("@/components/CalibrationQueuePanel"), {
  ssr: false,
  loading: () => (
    <section className="panel inset" role="status">
      <p className="muted">Loading calibration queue...</p>
    </section>
  ),
})

function RoleLibrary() {
  const id = useSearchParams().get("role")
  const list = useResource<CalibratedRole[]>(id ? null : "roles")
  const item = useResource<CalibratedRole>(id ? "roles/" + encodeURIComponent(id) : null)
  const { prepare } = usePreparation()
  const heading = useRef<HTMLHeadingElement>(null)
  const [detailStatus, setDetailStatus] = useState("")
  useEffect(() => { if (item.data) heading.current?.focus() }, [item.data?.id])
  const error = id ? item.error : list.error
  if (error) return <WorkspaceError text={error} retry={id ? item.reload : list.reload}/>
  if (id && item.data) {
    const role = item.data
    return <div className="stack">
      <Link href="/roles/" className="text-action inline-flex items-center min-h-[44px] md:min-h-0 w-fit rounded-sm focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--color-ring)]">All roles</Link>
      <header className="page-title"><h1 ref={heading} tabIndex={-1}>{role.name}</h1><p>{role.description}</p></header>
      {detailStatus && (
        <p role="status" aria-live="polite" className="rounded-md border border-[var(--success-line)] bg-[var(--success-bg)] px-3 py-2 text-sm text-[var(--success-text)]">
          {detailStatus}
        </p>
      )}
      <section className="panel stack"><h2>Interview plan</h2><p>{role.policy || "No assistance policy saved."}</p>
        {role.questions.length > 0 && <ol>{role.questions.map((question, i) => <li key={i}>{i + 1}. {question}</li>)}</ol>}
        {role.permitted_sources.map((source, i) => (
          <details key={i} className="rounded-md border border-[var(--line)] bg-[var(--subtle)] px-3 py-2">
            <summary className="cursor-pointer rounded-sm py-1.5 font-medium focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--color-ring)] focus-visible:ring-2 focus-visible:ring-[var(--color-ring)]/40">
              {source.label}
            </summary>
            <p className="mt-2 text-sm">{source.text}</p>
          </details>
        ))}
        {!!role.rubric?.length && (
          <div className="stack !gap-2">
            <h3>Rubric criteria ({role.rubric.length})</h3>
            {role.rubric.map((crit) => (
              <div key={crit.id} className="rounded-md border border-[var(--line)] bg-[var(--subtle)] p-3 text-sm">
                <strong>{crit.criterion}</strong> (weight {crit.weight})
              </div>
            ))}
          </div>
        )}
        <div><Button className="min-h-[44px] md:min-h-9" onClick={() => prepare({ candidate: "", role: role.name, roleId: role.id })}>Prepare interview</Button></div>
      </section>
      <RoleVersionHistory
        key={role.id}
        role={role}
        onRestored={(updated) => { setDetailStatus(`Reloaded ${updated.name} (v${updated.version_number ?? 1}).`); item.reload() }}
        onConflictReload={() => { setDetailStatus("Reloaded saved role."); item.reload() }}
      />
    </div>
  }
  if (!list.data) return <section className="panel inset" role="status"><p className="muted">Loading role library...</p></section>
  return <div className="stack">
    <Roles roles={list.data} onSave={role => list.update(old => [role, ...old.filter(row => row.id !== role.id)])}
      prepare={role => prepare({ candidate: "", role: role.name, roleId: role.id })} onReloadAll={list.reload}/>
    <CalibrationQueuePanel roles={list.data ?? []} />
    <Migration onImported={list.reload}/>
  </div>
}

export default function RolesPage() {
  return <Suspense fallback={<section className="panel inset" role="status"><p className="muted">Loading role library...</p></section>}><RoleLibrary/></Suspense>
}
