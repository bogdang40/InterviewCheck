import { useState } from "react"
import { Plus, RefreshCw, WandSparkles, X } from "lucide-react"
import { generateSources, pairKey, styles, type Pair, type useAuthoringRun } from "@/lib/authoring"
import type { Source } from "@/lib/api"
import { Button } from "./ui/button"

type Outcome = { state: "added" | "failed"; message: string }
type Props = {
  providers: string[]
  role: string
  question: string
  count: number
  append: (sources: Source[]) => void
  disabled: boolean
  runState: ReturnType<typeof useAuthoringRun>
}

function recipients(pairs: Pair[]) {
  return (
    `${pairs.length} ${pairs.length === 1 ? "request" : "requests"}: ` +
    pairs.map((pair) => pair.provider + " · " + pair.style).join(", ")
  )
}

export default function ReferenceLineup({
  providers,
  role,
  question,
  count,
  append,
  disabled,
  runState,
}: Props) {
  const [pairs, setPairs] = useState<Pair[]>([{ provider: providers[0], style: styles[0] }])
  const [report, setReport] = useState<{ context: string; outcomes: Record<string, Outcome> }>()
  const outcomes = report?.context === runState.context ? report.outcomes : {}
  function record(updated: Record<string, Outcome>) {
    setReport({ context: runState.context, outcomes: { ...outcomes, ...updated } })
  }
  const all = styles.flatMap((style) => providers.map((provider) => ({ provider, style })))
  const chosen = new Set(pairs.map(pairKey))
  const ready = pairs.filter((pair) => !outcomes[pairKey(pair)])
  const failed = pairs.filter((pair) => outcomes[pairKey(pair)]?.state === "failed")
  const next = all.find((pair) => !chosen.has(pairKey(pair)))
  const slots = 12 - count
  const blocked = disabled || runState.busy || !role || !question

  function choices(index: number) {
    const other = new Set(pairs.filter((_, i) => i !== index).map(pairKey))
    return all.filter((pair) => !other.has(pairKey(pair)))
  }
  function replace(index: number, pair: Pair) {
    setPairs((current) => current.map((value, i) => (i === index ? pair : value)))
  }
  function submit(requested: Pair[]) {
    if (blocked || !requested.length || requested.length > slots) return
    void runState.run(
      (signal) => generateSources(role, question, requested, count, signal),
      (rows) => {
        const sources: Source[] = []
        const updated: Record<string, Outcome> = {}
        for (const pair of requested) {
          const name = pairKey(pair)
          const row = rows.find((result) => pairKey(result) === name)
          if (row?.source) {
            sources.push(row.source)
            updated[name] = { state: "added", message: "Added to sources" }
          } else {
            updated[name] = { state: "failed", message: row?.error || "No reference was returned." }
          }
        }
        if (sources.length) append(sources)
        record(updated)
      },
      (error) => {
        record(Object.fromEntries(
          requested.map((pair) => [pairKey(pair), { state: "failed", message: error } as Outcome]),
        ))
      },
    )
  }

  return (
    <>
      {pairs.map((pair, index) => {
        const available = choices(index)
        const outcome = outcomes[pairKey(pair)]
        return (
          <fieldset className="recipient-row stack" key={index} disabled={runState.busy}>
            {pairs.length > 1 && <legend>Request {index + 1}</legend>}
            <div className="dual">
              <label className="field">
                Provider
                <select
                  value={pair.provider}
                  onChange={(e) => {
                    const sameFormat = available.find(
                      (item) => item.provider === e.target.value && item.style === pair.style,
                    )
                    const replacement =
                      sameFormat ?? available.find((item) => item.provider === e.target.value)
                    if (replacement) replace(index, replacement)
                  }}
                >
                  {providers.map((name) => (
                    <option key={name} disabled={!available.some((item) => item.provider === name)}>
                      {name}
                    </option>
                  ))}
                </select>
              </label>
              <label className="field">
                Answer format
                <select
                  value={pair.style}
                  onChange={(e) => replace(index, { ...pair, style: e.target.value })}
                >
                  {styles.map((style) => (
                    <option
                      key={style}
                      disabled={
                        !available.some((item) => item.provider === pair.provider && item.style === style)
                      }
                    >
                      {style}
                    </option>
                  ))}
                </select>
              </label>
            </div>
            {outcome && (
              <p role="status" className={outcome.state === "failed" ? "error" : "muted"}>
                {pair.provider} · {pair.style}: {outcome.message}
              </p>
            )}
            {pairs.length > 1 && (
              <div>
                <Button
                  type="button"
                  size="sm"
                  variant="ghost"
                  aria-label={`Remove request ${index + 1}`}
                  onClick={() => setPairs((current) => current.filter((_, i) => i !== index))}
                >
                  <X />
                  Remove
                </Button>
              </div>
            )}
          </fieldset>
        )
      })}
      <div>
        <Button
          type="button"
          size="sm"
          variant="ghost"
          disabled={runState.busy || !next || pairs.length >= 3}
          onClick={() => {
            if (next) setPairs((current) => [...current, next])
          }}
        >
          <Plus />
          Add provider and format
        </Button>
      </div>
      {ready.length > 0 && (
        <div className="stack">
          <p className="muted">{recipients(ready)}</p>
          <div>
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={blocked || ready.length > slots}
              onClick={() => submit(ready)}
            >
              <WandSparkles />
              {runState.busy
                ? "Generating…"
                : ready.length === 1
                  ? "Generate reference"
                  : "Generate references"}
            </Button>
          </div>
        </div>
      )}
      {failed.length > 0 && (
        <div className="stack">
          <p className="muted">Retry {recipients(failed)}</p>
          <div>
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={blocked || failed.length > slots}
              onClick={() => submit(failed)}
            >
              <RefreshCw />
              Retry failed
            </Button>
          </div>
        </div>
      )}
      {(ready.length > slots || failed.length > slots) && (
        <p className="notice">
          Available reference slots: {slots} of 12. Reduce the selection or remove an existing source.
        </p>
      )}
    </>
  )
}
