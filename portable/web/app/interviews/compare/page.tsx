"use client"

import { Suspense } from "react"
import CompareDossierView from "@/components/CompareDossierView"

export default function ComparePage() {
  return (
    <Suspense fallback={<section className="panel inset" role="status"><p className="muted">Loading comparison…</p></section>}>
      <CompareDossierView />
    </Suspense>
  )
}
