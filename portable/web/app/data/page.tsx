"use client"

import dynamic from "next/dynamic"
import WorkspaceBackup from "@/components/WorkspaceBackup"

const CohortAnalyticsPanel = dynamic(() => import("@/components/CohortAnalyticsPanel"), {
  ssr: false,
  loading: () => (
    <section className="panel inset" role="status">
      <p className="muted">Loading cohort analytics...</p>
    </section>
  ),
})

export default function DataPage() {
  return (
    <>
      <div className="page-title">
        <h1>Workspace data</h1>
        <p>Back up interviews, restore records, or inspect cohort analytics.</p>
      </div>
      <WorkspaceBackup />
      <CohortAnalyticsPanel />
    </>
  )
}
