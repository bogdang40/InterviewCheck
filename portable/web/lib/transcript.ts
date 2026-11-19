export type Cue = { speaker: string; text: string; start: number; end: number }
export type Exchange = { question: string; answer: string; ordinal: number; start_ms: number; end_ms: number; first_cue: number; last_cue: number }

function milliseconds(stamp: string) {
  const match = stamp.match(/^(?:(\d{1,3}):)?([0-5]\d):([0-5]\d)[.,](\d{3})$/)
  if (!match) throw new Error("A cue contains an invalid WebVTT timestamp.")
  return ((Number(match[1] || 0) * 60 + Number(match[2])) * 60 + Number(match[3])) * 1000 + Number(match[4])
}

function decode(text: string) {
  return text.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&nbsp;/g, " ").replace(/&amp;/g, "&")
}

export function readCues(input: string, strict = false): Cue[] {
  const normalized = input.replace(/^\uFEFF/, "").replace(/\r\n?/g, "\n")
  if (strict && !/^WEBVTT(?:[ \t].*)?(?:\n|$)/.test(normalized)) throw new Error("Select a WebVTT file with a WEBVTT header.")
  const cues: Cue[] = []
  for (const block of normalized.split(/\n[ \t]*\n/)) {
    const lines = block.trim().split("\n")
    if (/^(?:WEBVTT|NOTE|STYLE|REGION)(?:\s|$)/.test(lines[0]) || !lines[0]) continue
    const timing = lines.findIndex(line => line.includes("-->"))
    if (timing < 0 && !strict) continue
    const stamps = lines[timing]?.match(/^\s*(\S+)\s+-->\s+(\S+)(?:\s.*)?$/)
    if (!stamps) throw new Error("A WebVTT block has no valid time range.")
    const start = milliseconds(stamps[1]), end = milliseconds(stamps[2])
    if (end < start) throw new Error("A transcript cue ends before it starts.")
    if (strict && cues.length && start < cues[cues.length - 1].start) {
      throw new Error("The WebVTT cues are out of time order. Check the source before importing.")
    }
    const body = lines.slice(timing + 1)
    const raw = body.join(" ").trim()
    if (!raw) continue
    const tagged = raw.match(/^<v(?:\.[^\s>]+)?\s+([^>]+)>([\s\S]*)/i)
    const named = tagged || raw.match(/^([^:<>]{1,180}):\s+(.+)/)
    if (!named) throw new Error("Each cue needs a speaker name. Paste the selected question and answer instead.")
    if (/<v[\s.]/i.test(named[2]) || (!tagged && body.slice(1).some(line => /^[^:<>]{1,180}:\s+/.test(line)))) {
      throw new Error("This cue contains multiple speakers. Split it into separate cues before importing.")
    }
    const speaker = decode(named[1].trim()), text = decode(named[2].replace(/<[^>]*>/g, "")).trim()
    if (!speaker || speaker.length > 180) throw new Error("Each speaker needs a name of at most 180 characters.")
    if (text) cues.push({ speaker, text, start, end })
    if (strict && cues.length > 10000) throw new Error("Select a transcript with at most 10,000 cues.")
  }
  if (new Set(cues.map(c => c.speaker)).size < 2) throw new Error("Select a WebVTT file with at least two named speakers.")
  return cues
}

export function transcriptSelection(cues: Cue[], candidate: string, interviewers: string[]) {
  const hosts = new Set(interviewers)
  const rows: Exchange[] = []
  let unprompted = 0, unanswered = 0, excluded = 0
  let prompt: string[] = [], response: string[] = [], start = 0, end = 0, first = 0, last = 0
  function flush() {
    if (prompt.length && response.length) rows.push({ question: prompt.join(" "), answer: response.join(" "),
      ordinal: rows.length + 1, start_ms: start, end_ms: end, first_cue: first, last_cue: last })
    else if (prompt.length) unanswered++
    else if (response.length) unprompted++
    prompt = []; response = []
  }
  for (const [index, cue] of cues.entries()) {
    if (cue.speaker === candidate) {
      last = index + 1
      response.push(cue.text)
      end = Math.max(end, cue.end)
    } else if (hosts.has(cue.speaker)) {
      if (response.length) flush()
      if (!prompt.length) { first = index + 1; start = cue.start; end = cue.end }
      prompt.push(cue.text)
      end = Math.max(end, cue.end)
    } else {
      // An unnamed role can break the connection between a prompt and a reply.
      flush(); excluded++
    }
  }
  flush()
  return { rows, unprompted, unanswered, excluded }
}

export function exchanges(cues: Cue[], candidate: string): Exchange[] {
  return transcriptSelection(cues, candidate, [...new Set(cues.map(c => c.speaker))].filter(s => s !== candidate)).rows
}
