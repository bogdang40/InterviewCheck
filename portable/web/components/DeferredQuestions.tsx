"use client"

import dynamic from "next/dynamic"
import { useState } from "react"
import type { Answer, Draft, Interview } from "@/lib/api"
import type { DirtyReporter } from "@/lib/dirtyTracking"

export type DeferredQueueProps = {
  session: Interview; parent?: Answer; locked: boolean; onDirty: DirtyReporter
  onUnavailable: () => void; openDraft: (draft: Draft) => void; foundDraft: (draft: Draft) => void; select: (id: string) => void
}


const DeferredQuestionQueue = dynamic(() => import("./DeferredQuestionQueue"), {
  ssr: false,
  loading: () => <p role="status">Loading deferred questions…</p>,
})

export default function DeferredQuestions({ detailsRef, ...props }: DeferredQueueProps & {
  detailsRef: (node: HTMLDetailsElement | null) => void
}) {
  const [started, setStarted] = useState(false)
  const [open, setOpen] = useState(false)
  return <details ref={detailsRef} id="deferred-questions" className="panel inset stack"
    onToggle={e => { setOpen(e.currentTarget.open); if (e.currentTarget.open) setStarted(true) }}>
    <summary className="cursor-pointer font-semibold">Questions for later</summary>
    {started && <DeferredQuestionQueue {...props} open={open} />}
  </details>
}
