import type { Passage } from "@/lib/api"

type Range = { start: number; end: number; label: string }

// Stored coordinates count Unicode code points, as Python does. Older records
// only have excerpts, so highlight a legacy excerpt only if its position is unique.
export default function MarkedText({
  text,
  passages,
  side = "answer",
}: {
  text: string
  passages: Passage[]
  side?: "answer" | "source"
}) {
  const chars = Array.from(text)
  const ranges: Range[] = []
  for (const p of passages) {
    const span = side === "answer" ? p.answer_span : p.source_span
    const excerpt = side === "answer" ? p.answer_excerpt : p.source_excerpt
    if (!excerpt) continue
    if (
      span &&
      Number.isInteger(span[0]) &&
      Number.isInteger(span[1]) &&
      span[0] >= 0 &&
      span[1] <= chars.length &&
      span[1] > span[0] &&
      chars
        .slice(...span)
        .join("")
        .startsWith(excerpt)
    ) {
      ranges.push({ start: span[0], end: span[1], label: p.label })
    } else if (!span) {
      const first = text.indexOf(excerpt)
      if (first >= 0 && text.indexOf(excerpt, first + 1) < 0) {
        const start = Array.from(text.slice(0, first)).length
        ranges.push({ start, end: start + Array.from(excerpt).length, label: p.label })
      }
    }
  }
  if (!ranges.length) return <>{text}</>
  const bounds = [...new Set([0, chars.length, ...ranges.flatMap((r) => [r.start, r.end])])].sort(
    (a, b) => a - b,
  )
  return (
    <>
      {bounds.slice(1).map((end, i) => {
        const start = bounds[i]
        const labels = ranges.filter((r) => r.start <= start && end <= r.end).map((r) => r.label)
        const part = chars.slice(start, end).join("")
        return labels.length ? (
          <mark className="matched-text" key={start} title={labels.join(", ")}>
            {part}
          </mark>
        ) : (
          part
        )
      })}
    </>
  )
}
