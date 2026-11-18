import { useState } from "react"
import { readCues, exchanges } from "@/lib/transcript"
import { Button } from "./ui/button"
import { message } from "@/lib/api"

export default function TranscriptImport({ apply }: { apply: (q: string, a: string) => void }) {
  const [cues, setCues] = useState<ReturnType<typeof readCues>>([])
  const [speaker, setSpeaker] = useState("")
  const [error, setError] = useState("")
  const [index, setIndex] = useState(0)
  const items = exchanges(cues, speaker)
  return (
    <details className="import">
      <summary>Import a meeting transcript</summary>
      <div className="stack">
        <label className="field">
          WebVTT file
          <input
            type="file"
            accept=".vtt,text/vtt"
            onChange={async (e) => {
              const file = e.target.files?.[0]
              setCues([])
              setSpeaker("")
              setIndex(0)
              setError("")
              if (!file) return
              try {
                if (file.size > 2_000_000) throw new Error("Select a transcript under 2 MB.")
                setCues(readCues(await file.text()))
              } catch (e) {
                setError(message(e))
              }
            }}
          />
        </label>
        {cues.length > 0 && (
          <label className="field">
            Candidate speaker
            <select
              value={speaker}
              onChange={(e) => {
                setSpeaker(e.target.value)
                setIndex(0)
              }}
            >
              <option value="">Select a speaker</option>
              {Array.from(new Set(cues.map((c) => c.speaker))).map((s) => (
                <option key={s}>{s}</option>
              ))}
            </select>
          </label>
        )}
        {speaker &&
          (items.length ? (
            <>
              <label className="field">
                Exchange
                <select value={index} onChange={(e) => setIndex(Number(e.target.value))}>
                  {items.map((x, i) => (
                    <option key={i} value={i}>
                      {i + 1}. {x.question.slice(0, 90)}
                    </option>
                  ))}
                </select>
              </label>
              <p>{items[index].answer}</p>
              <div>
                <Button
                  type="button"
                  variant="outline"
                  onClick={() => apply(items[index].question, items[index].answer)}
                >
                  Use this exchange
                </Button>
              </div>
            </>
          ) : (
            <p>No answers follow another speaker in this file.</p>
          ))}
        {error && (
          <p className="error" role="alert">
            {error}
          </p>
        )}
      </div>
    </details>
  )
}
