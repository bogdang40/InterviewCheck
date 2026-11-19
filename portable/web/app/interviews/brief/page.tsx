"use client"

import Link from "next/link"
import { useSearchParams } from "next/navigation"
import { Suspense } from "react"
import { Button } from "@/components/ui/button"
import ReviewBrief from "@/components/ReviewBrief"

function PageContent() {
  const id = useSearchParams().get("id")
  if (!id)
    return (
      <section className="panel stack">
        <div className="page-title">
          <span className="eyebrow">BRIEF</span>
          <h1>Review brief</h1>
          <p>Select an interview to prepare its brief.</p>
        </div>
        <div>
          <Button asChild variant="outline" size="sm">
            <Link href="/interviews/">Open interviews</Link>
          </Button>
        </div>
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
