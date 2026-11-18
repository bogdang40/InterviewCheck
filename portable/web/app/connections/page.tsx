"use client"

import Connections from "@/components/Connections"
import { usePreparation } from "@/lib/workspace"

export default function ConnectionsPage() {
  const { prepare } = usePreparation()
  return (
    <>
      <div className="page-title">
        <h1>Connections</h1>
        <p>Prepare interviews from connected systems and manage account access.</p>
      </div>
      <Connections onPrepare={(candidate, role) => prepare({ candidate, role })} />
    </>
  )
}
