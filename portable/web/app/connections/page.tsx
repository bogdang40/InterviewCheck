"use client"

import Connections from "@/components/Connections"
import { usePreparation } from "@/lib/workspace"

export default function ConnectionsPage() {
  const { prepare } = usePreparation()
  return (
    <>
      <div className="page-title">
        <h1>Connections</h1>
        <p>Find setup requirements and prepare interviews from calendars or applicant tracking systems.</p>
      </div>
      <Connections onPrepare={(candidate, role) => prepare({ candidate, role })} />
    </>
  )
}
