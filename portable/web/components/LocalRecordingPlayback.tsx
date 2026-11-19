"use client"

import { useEffect, useLayoutEffect, useState } from "react"
import { Volume2 } from "lucide-react"
import { Button } from "./ui/button"
import { ExcerptPlayer } from "./ExcerptPlayer"
import type { Answer } from "@/lib/api"
import styles from "./LocalRecordingPlayback.module.css"

function timestamp(ms: number) {
  const seconds = Math.floor(ms / 1000)
  const hours = Math.floor(seconds / 3600)
  const minutes = String(Math.floor(seconds / 60) % 60).padStart(2, "0")
  return (
    (hours ? hours + ":" : "") +
    minutes +
    ":" +
    String(seconds % 60).padStart(2, "0") +
    "." +
    String(ms % 1000).padStart(3, "0")
  )
}

export default function LocalRecordingPlayback({
  sessionId,
  selectedAnswer,
  disabled = false,
}: {
  sessionId: string
  selectedAnswer?: Answer
  disabled?: boolean
}) {
  const [selection, setSelection] = useState<{
    session: string
    fingerprint: string
    file: File
    sequence: number
  }>()
  const [error, setError] = useState("")
  const [open, setOpen] = useState(false)
  useEffect(() => {
    // A browser may retain the document for Back navigation without unmounting React.
    const forget = () => setSelection(undefined)
    window.addEventListener("pagehide", forget)
    return () => window.removeEventListener("pagehide", forget)
  }, [])
  const origin = selectedAnswer?.import_origin
  const fingerprint = origin?.transcript_sha256
  const file =
    selection?.session === sessionId && selection.fingerprint === fingerprint ? selection.file : undefined
  useLayoutEffect(() => {
    setSelection((old) =>
      old && (old.session !== sessionId || old.fingerprint !== fingerprint) ? undefined : old,
    )
    setError("")
  }, [fingerprint, sessionId])
  // InterviewView keys this component by session. A question change retains the operator's file.
  return (
    <details className={`panel ${styles.panel}`} onToggle={(e) => setOpen(e.currentTarget.open)}>
      <summary>
        <Volume2 aria-hidden size={16} />
        Local recording playback
      </summary>
      <div className="stack">
        <p className="muted">
          Select the recording that matches this transcript. The file stays in this browser tab.
        </p>
        {origin ? (
          <div className={styles.range}>
            <strong>{origin.candidate_speaker}</strong>
            <span>
              Exchange interval {timestamp(origin.start_ms)} to {timestamp(origin.end_ms)}
            </span>
          </div>
        ) : (
          <p>This exchange has no WebVTT source interval.</p>
        )}
        {file ? (
          <div className="spread">
            <strong className={styles.file}>{file.name}</strong>
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={() => {
                setSelection(undefined)
                setError("")
              }}
            >
              Remove recording
            </Button>
          </div>
        ) : (
          <label className="field">
            Corresponding local recording
            <input
              type="file"
              accept="audio/*,video/*"
              disabled={disabled || !origin}
              onChange={(e) => {
                const chosen = e.target.files?.[0]
                e.target.value = ""
                if (!chosen || !fingerprint) return
                if (!chosen.size) {
                  setError("Choose a recording that contains media.")
                  return
                }
                setError("")
                setSelection((last) => ({
                  session: sessionId,
                  fingerprint,
                  file: chosen,
                  sequence: (last?.sequence || 0) + 1,
                }))
              }}
            />
          </label>
        )}
        {error && (
          <p className="error" role="alert">
            {error}
          </p>
        )}
        {file && (
          <ExcerptPlayer
            key={selection?.sequence}
            file={file}
            selectedId={selectedAnswer?.id}
            origin={origin}
            disabled={disabled || !open}
          />
        )}
      </div>
    </details>
  )
}
