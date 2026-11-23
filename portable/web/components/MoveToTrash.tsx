"use client"

import { useRouter } from "next/navigation"
import { useState } from "react"
import { Trash2 } from "lucide-react"
import { api, message } from "@/lib/api"
import { rememberMove, type TrashedInterview } from "@/lib/trash"
import { sweepLocalDrafts } from "@/lib/localDraftSweep"
import { Button } from "./ui/button"

export default function MoveToTrash({
  sessionId,
  candidate,
  disabled = false,
}: {
  sessionId: string
  candidate: string
  disabled?: boolean
}) {
  const router = useRouter()
  const [confirm, setConfirm] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  async function move() {
    if (!confirm || disabled || busy) return
    setBusy(true)
    setError("")
    try {
      const entry = await api<TrashedInterview>(`sessions/${sessionId}/trash`, "POST")
      sweepLocalDrafts([sessionId])
      rememberMove(entry)
      router.replace("/trash/")
    } catch (e) {
      setError(message(e))
      setBusy(false)
    }
  }
  return (
    <section aria-label="Interview removal">
      {!confirm ? (
        <Button type="button" disabled={disabled} size="sm" variant="ghost" onClick={() => setConfirm(true)}>
          <Trash2 />
          Move to Trash
        </Button>
      ) : (
        <div className="notice stack">
          <strong>Move this interview for {candidate || "unnamed candidate"} to Trash?</strong>
          <p>You can restore the interview and its saved work from Trash. Moving it clears unsaved local copies for this interview in this browser.</p>
          <div className="row">
            <Button type="button" variant="outline" size="sm" disabled={disabled || busy} onClick={move}>
              {busy ? "Moving…" : "Confirm move to Trash"}
            </Button>
            <Button
              type="button"
              variant="ghost"
              size="sm"
              disabled={busy}
              onClick={() => {
                setConfirm(false)
                setError("")
              }}
            >
              Cancel
            </Button>
          </div>
          {error && (
            <p role="alert" className="error">
              {error}
            </p>
          )}
        </div>
      )}
    </section>
  )
}
