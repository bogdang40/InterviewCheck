"use client"

import { Suspense, useCallback, useState } from "react"
import dynamic from "next/dynamic"
import InterviewArchive from "@/components/InterviewArchive"
import { usePreparation } from "@/lib/workspace"
import "@/app/queue.css"

const ArchiveAssignmentsStrip = dynamic(() => import("@/components/ArchiveAssignmentsStrip"), {
  ssr: false,
  loading: () => null,
})

export default function InterviewsPage() {
  const { prepare } = usePreparation()
  const [archiveReady, setArchiveReady] = useState(false)
  const handleArchiveReady = useCallback(() => setArchiveReady(true), [])
  return (
    <div className="stack">
      <Suspense fallback={<h1>Interviews</h1>}>
        <InterviewArchive onCreate={() => prepare()} onReady={handleArchiveReady} />
      </Suspense>
      {archiveReady && <ArchiveAssignmentsStrip />}
    </div>
  )
}
