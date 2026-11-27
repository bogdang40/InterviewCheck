"use client"

import dynamic from "next/dynamic"
import { useState } from "react"
import type { Answer, Interview } from "@/lib/api"
import type { WorksheetState } from "@/lib/reviewWorksheet"

export type WorksheetProps = {
  item: Answer; ordinal: number; session: Interview; editorBusy: boolean
  stage: (state: WorksheetState, note: string) => void
  onDenied: () => void
}

const WorksheetControls = dynamic(() => import("./WorksheetControls"), {
  ssr: false,
  loading: () => <p role="status">Loading worksheet controls…</p>,
})

export default function ReviewWorksheet(props: WorksheetProps) {
  const [opened, setOpened] = useState(false)
  const [open, setOpen] = useState(false)
  return <details className="panel inset stack" onToggle={event => {
    const visible = event.currentTarget.open
    setOpen(visible)
    if (visible) setOpened(true)
  }}>
    <summary>Offline review worksheet</summary>
    {opened && <WorksheetControls {...props} open={open} />}
  </details>
}
