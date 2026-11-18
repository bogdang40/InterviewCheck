type Exchange = { question: string; answer: string }
type Cue = { speaker: string; text: string }

export function readCues(input: string): Cue[] {
  const cues: Cue[] = []
  for (const block of input
    .replace(/^\uFEFF/, "")
    .replace(/\r\n?/g, "\n")
    .split(/\n[ \t]*\n/)) {
    const lines = block.split("\n")
    const timing = lines.findIndex((line) => /^\s*(?:\d+:)?\d{2}:\d{2}[.,]\d{3}\s+-->/.test(line))
    if (timing < 0) continue
    const raw = lines
      .slice(timing + 1)
      .join(" ")
      .trim()
    const tagged = raw.match(/^<v(?:\.[^\s>]+)?\s+([^>]+)>([\s\S]*)/i)
    const named = tagged || raw.match(/^([^:<>]{1,80}):\s+(.+)/)
    if (!named)
      throw new Error("Each cue needs a speaker name. Paste the selected question and answer instead.")
    if (/<v[\s.]/i.test(named[2]))
      throw new Error("This cue contains multiple speakers. Paste the selected exchange instead.")
    const text = named[2]
      .replace(/<[^>]*>/g, "")
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/&amp;/g, "&")
      .trim()
    if (text) cues.push({ speaker: named[1].trim(), text })
  }
  if (new Set(cues.map((c) => c.speaker)).size < 2)
    throw new Error("Select a WebVTT file with at least two named speakers.")
  return cues
}

export function exchanges(cues: Cue[], candidate: string): Exchange[] {
  const result: Exchange[] = []
  let question = "",
    answer = ""
  for (const cue of cues) {
    if (cue.speaker === candidate) {
      if (question) answer = [answer, cue.text].filter(Boolean).join(" ")
      continue
    }
    if (answer) {
      result.push({ question, answer })
      question = ""
      answer = ""
    }
    question = [question, cue.text].filter(Boolean).join(" ")
  }
  if (answer) result.push({ question, answer })
  return result
}
