"use client"

import { Suspense } from "react"
import InterviewArchive from "@/components/InterviewArchive"
import { usePreparation } from "@/lib/workspace"
import "@/app/queue.css"

export default function InterviewsPage() {
  const { prepare } = usePreparation()
  return (
    <Suspense fallback={<h1>Interviews</h1>}>
      <InterviewArchive onCreate={() => prepare()} />
    </Suspense>
  )
}
