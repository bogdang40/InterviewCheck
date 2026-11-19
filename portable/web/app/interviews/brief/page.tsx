"use client"

import Link from "next/link"
import { useSearchParams } from "next/navigation"
import { Suspense } from "react"
import ReviewBrief from "@/components/ReviewBrief"

function PageContent() {
  const id = useSearchParams().get("id")
  if (!id)
    return (
      <section className="panel stack">
        <h1>Review brief</h1>
        <p>Select an interview to prepare its brief.</p>
        <Link href="/interviews/" className="queue-link">
          Open interviews
        </Link>
      </section>
    )
  return <ReviewBrief key={id} sessionId={id} />
}

export default function BriefPage() {
  return (
    <Suspense fallback={<h1>Review brief</h1>}>
      <PageContent />
    </Suspense>
  )
}
