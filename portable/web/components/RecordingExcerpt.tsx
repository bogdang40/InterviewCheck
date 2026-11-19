"use client"

import { useMemo, useState } from "react"
import { Button } from "@/components/ui/button"
import { Textarea } from "@/components/ui/textarea"
import type { Segment } from "./MeetingRecordings"

function speakerTurns(segments: Segment[]) {
  const turns: Segment[] = []
  for (const segment of segments) {
    const last = turns.at(-1)
    if (last?.speaker === segment.speaker) last.text += " " + segment.text
    else turns.push({ ...segment })
  }
  return turns
}

type Pick = { speaker: string; turn: string; text: string }

// The parent remounts the picker for each accepted recording. A single state
// update changes the display selection, the editable text, and use eligibility.
export function RecordingExcerpt({ segments, onApply, onDiscard }: {
  segments: Segment[]; onApply: (text: string) => void; onDiscard: () => void
}) {
  const turns = useMemo(() => speakerTurns(segments), [segments])
  const [pick, setPick] = useState<Pick>({ speaker: "", turn: "", text: "" })
  const choices = turns.filter(turn => turn.speaker === pick.speaker)
  const original = pick.turn === "" ? undefined : choices[Number(pick.turn)]
  function select(next: Pick) {
    if (original && pick.text !== original.text && !window.confirm("Discard your edits to the selected excerpt?")) return
    setPick(next)
  }
  return <div className="stack">
    <label className="field">Candidate voice
      <select value={pick.speaker} onChange={event => select({ speaker: event.target.value, turn: "", text: "" })}>
        <option value="">Select a speaker</option>
        {[...new Set(turns.map(turn => turn.speaker))].map(speaker => <option key={speaker} value={speaker}>
          {speaker === "Unknown" ? "Unassigned voice" : speaker} · {turns.find(turn => turn.speaker === speaker)?.text.slice(0, 64)}
        </option>)}
      </select>
    </label>
    {pick.speaker && <label className="field">Answer excerpt
      <select value={pick.turn} onChange={event => {
        const index = event.target.value
        select({ speaker: pick.speaker, turn: index, text: index === "" ? "" : choices[Number(index)].text })
      }}>
        <option value="">Select the candidate’s turn</option>
        {choices.map((turn, i) => <option key={i} value={i}>{i + 1}. {turn.text.slice(0, 100)}</option>)}
      </select>
    </label>}
    <label className="field">Candidate excerpt
      <Textarea rows={4} disabled={!original} value={pick.text}
        onChange={event => setPick({ ...pick, text: event.target.value })}/>
    </label>
    <Button type="button" variant="outline" disabled={!original || !pick.text.trim()}
      onClick={() => { if (original && pick.text.trim()) onApply(pick.text.trim()) }}>Use this excerpt</Button>
    <Button type="button" variant="ghost" onClick={onDiscard}>Discard excerpt</Button>
  </div>
}
