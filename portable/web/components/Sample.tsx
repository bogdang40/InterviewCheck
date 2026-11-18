import { useEffect, useState } from "react"
import { FlaskConical, Plus } from "lucide-react"
import { api, message, type Answer } from "@/lib/api"
import { sampleAnswer, sampleQuestion, sampleSources } from "@/lib/sample"
import { Button } from "./ui/button"
import { Findings } from "./Evidence"

export default function Sample({ create }: { create: () => void }) {
  const [permitted, setPermitted] = useState(false)
  const [result, setResult] = useState<Answer["result"] | null>(null),
    [error, setError] = useState("")
  const [retry, setRetry] = useState(0)
  useEffect(() => {
    let active = true
    setResult(null)
    setError("")
    api<Answer["result"]>("preview", "POST", {
      question: sampleQuestion,
      answer: sampleAnswer,
      references: sampleSources.map((s) => ({ ...s, permitted })),
    })
      .then((r) => {
        if (active) setResult(r)
      })
      .catch((e) => {
        if (active) setError(message(e))
      })
    return () => {
      active = false
    }
  }, [permitted, retry])
  return (
    <>
      <div className="page-title spread">
        <div>
          <span className="eyebrow">
            <FlaskConical size={14} /> FICTIONAL SESSION
          </span>
          <h1>Sample review</h1>
          <p>Change the source permission to see how it affects this comparison.</p>
        </div>
        <Button variant="outline" onClick={create}>
          <Plus />
          New interview
        </Button>
      </div>
      <section className="panel evidence">
        <span className="eyebrow">SYSTEM DESIGN</span>
        <h2>{sampleQuestion}</h2>
        <p className="transcript-text">{sampleAnswer}</p>
        <div className="source-box">
          <b>Practice answer</b>
          <p>{sampleSources[0].text}</p>
          <label className="check">
            <input type="checkbox" checked={permitted} onChange={(e) => setPermitted(e.target.checked)} />
            Permitted material
          </label>
        </div>
        {result && <Findings result={result} />}{" "}
        {error && (
          <p className="error" role="alert">
            {error}{" "}
            <Button variant="outline" onClick={() => setRetry((x) => x + 1)}>
              Retry
            </Button>
          </p>
        )}
        {!result && !error && <p role="status">Comparing passages…</p>}
      </section>
    </>
  )
}
