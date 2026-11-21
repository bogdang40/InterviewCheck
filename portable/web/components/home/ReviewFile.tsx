"use client"

import { useEffect, useMemo, useRef, useState } from "react"
import { practiceCases } from "@/lib/sample"

type Passage = { words: number; label: string; answer_span?: [number, number]; source_span?: [number, number] }
type Result = { status: string; follow_up: string; passages: Passage[] }

const example = practiceCases[0]
const source = example.sources[0]

// What the comparison returns for this case today; shown if the live call cannot be made.
const recorded: Result = {
  status: "match",
  follow_up:
    "You said “We give checkout a separate pool of workers so a slow inventory”. Which part would you change under a different constraint, and why?",
  passages: [{ words: 18, label: source.label, answer_span: [38, 150], source_span: [36, 148] }],
}

// word: index of a shared word; gap: the space before shared word n, lit with it so the passage reads as one mark.
type Piece = { text: string; word: number | null; gap?: number }

/** Splits text so every word inside the span can be marked on its own. */
function pieces(text: string, span: [number, number] | undefined): Piece[] {
  if (!span) return [{ text, word: null }]
  const [start, end] = span
  const out: Piece[] = [{ text: text.slice(0, start), word: null }]
  let n = 0
  for (const part of text.slice(start, end).split(/(\s+)/)) {
    if (!part) continue
    out.push(/\s/.test(part) ? { text: part, word: null, gap: n } : { text: part, word: n++ })
  }
  out.push({ text: text.slice(end), word: null })
  return out
}

function Marked({ text, span, lit }: { text: string; span?: [number, number]; lit: number }) {
  const parts = useMemo(() => pieces(text, span), [text, span])
  return (
    <>
      {parts.map((p, i) =>
        p.gap !== undefined ? (
          <mark key={i} className={p.gap < lit ? "w gap on" : "w gap"}>
            {p.text}
          </mark>
        ) : p.word === null ? (
          <span key={i}>{p.text}</span>
        ) : (
          <mark key={i} className={p.word < lit ? "w on" : "w"}>
            {p.text}
          </mark>
        ),
      )}
    </>
  )
}

/** Two digit wheels; each change rolls the new digit in. */
function Count({ value }: { value: number }) {
  const digits = String(value).padStart(2, "0").split("")
  return (
    <span className="file-count" aria-hidden="true">
      {digits.map((d, i) => (
        <span className="digit" key={i + ":" + d}>
          {d}
        </span>
      ))}
    </span>
  )
}

export default function ReviewFile() {
  const [result, setResult] = useState<Result | null>(null)
  const [lit, setLit] = useState(0)
  const [seen, setSeen] = useState(false)
  const ref = useRef<HTMLElement>(null)

  useEffect(() => {
    const controller = new AbortController()
    fetch("/api/sample/preview", {
      method: "POST",
      signal: controller.signal,
      headers: { "Content-Type": "application/json", "X-InterviewCheck": "1" },
      body: JSON.stringify({ case_id: example.id }),
    })
      .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
      .then((r: Result) => setResult(r.passages?.length ? r : recorded))
      .catch(() => {
        if (!controller.signal.aborted) setResult(recorded)
      })
    return () => controller.abort()
  }, [])

  useEffect(() => {
    const el = ref.current
    if (!el) return
    const io = new IntersectionObserver(([entry]) => entry.isIntersecting && setSeen(true), { threshold: 0.35 })
    io.observe(el)
    return () => io.disconnect()
  }, [])

  const passage = result?.passages[0]
  const total = passage?.words ?? 0

  useEffect(() => {
    if (!seen || !total) return
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      setLit(total)
      return
    }
    let n = 0
    const timer = window.setInterval(() => {
      n += 1
      setLit(n)
      if (n >= total) window.clearInterval(timer)
    }, 70)
    return () => window.clearInterval(timer)
  }, [seen, total])

  const done = total > 0 && lit >= total

  return (
    <figure ref={ref} className="file" aria-label="Fictional example of a review file for one answer">
      <div className="file-tabs" aria-hidden="true">
        <span>Policy</span>
        <span className="current">Answer</span>
        <span>Sources</span>
        <span>Follow-up</span>
        <span>Outcome</span>
      </div>
      <div className="file-body">
        <p className="file-meta">
          <span>Fictional example</span>
          <span>Backend engineer · question 1</span>
        </p>
        <p className="file-question">{example.question}</p>

        <div className="file-text">
          <span className="file-label">Candidate said</span>
          <p>
            <Marked text={example.answer} span={passage?.answer_span} lit={lit} />
          </p>
        </div>

        <div className="file-text file-source">
          <span className="file-label">
            {source.label} <span className="file-flag">not permitted</span>
          </span>
          <p>
            <Marked text={source.text} span={passage?.source_span} lit={lit} />
          </p>
        </div>

        <div className={done ? "file-finding done" : "file-finding"}>
          <Count value={lit} />
          <p>
            words shared, in order, with <b>{source.label}</b>
          </p>
          <span className="sr-only" aria-live="polite">
            {done ? `${total} words shared with ${source.label}.` : ""}
          </span>
        </div>

        <div className={done ? "file-ask shown" : "file-ask"}>
          <span className="file-label">Ask next</span>
          <p>{(result ?? recorded).follow_up}</p>
        </div>

        <div className="file-outcome">
          <span className="file-label">Your call</span>
          <span className="chip">Explained</span>
          <span className="chip">Unresolved</span>
          <span className="chip">Disclosed assistance</span>
        </div>
      </div>
    </figure>
  )
}
