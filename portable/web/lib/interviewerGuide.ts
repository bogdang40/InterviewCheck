import { revisionNumber } from "./revisionNumber"
import type { CalibratedRole } from "./roleCalibration"

export type GuideRole = Pick<CalibratedRole, "name" | "version_number" | "version_number_text" | "questions" | "policy" | "rubric" | "permitted_sources">
export type GuideOptions = { rubric: boolean; materials: boolean }

export const guideStyles = `
.interviewer-guide { box-sizing: border-box; max-width: 48rem; margin: 0 auto; padding: clamp(1rem, 4vw, 2.5rem);
  background: white; color: #17251f; font: 1rem/1.55 system-ui, sans-serif; overflow-wrap: anywhere; }
.interviewer-guide h1 { margin: 0 0 .25rem; font-size: clamp(1.65rem, 4vw, 2.25rem); line-height: 1.2; }
.interviewer-guide h2 { margin: 1.6rem 0 .5rem; padding-top: .55rem; border-top: 1px solid #a5b2aa; font-size: 1.25rem; }
.interviewer-guide h3 { margin: 1rem 0 .2rem; font-size: 1.05rem; }
.interviewer-guide p, .interviewer-guide li { white-space: pre-wrap; }
.interviewer-guide p { margin: .4rem 0; }
.interviewer-guide ol, .interviewer-guide ul { margin: .4rem 0; padding-inline-start: 1.75rem; }
.interviewer-guide ol { list-style: decimal; }
.interviewer-guide ul { list-style: disc; }
.interviewer-guide li { margin: .4rem 0; }
@media print {
  .interviewer-guide { max-width: none; padding: 0; font-size: 11pt; }
  .interviewer-guide h1, .interviewer-guide h2, .interviewer-guide h3 { break-after: avoid; }
  .interviewer-guide li { break-inside: avoid; }
  .interviewer-guide p { orphans: 3; widows: 3; }
}
`

// Build only the selected sections. Every saved role field enters the document as text.
export function guideDocument(role: GuideRole, options: GuideOptions): Document {
  const doc = document.implementation.createHTMLDocument(role.name + " | Interviewer guide")
  doc.documentElement.lang = "en"
  const charset = doc.createElement("meta")
  charset.setAttribute("charset", "utf-8")
  const csp = doc.createElement("meta")
  csp.httpEquiv = "Content-Security-Policy"
  csp.content = "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"
  const viewport = doc.createElement("meta")
  viewport.name = "viewport"
  viewport.content = "width=device-width, initial-scale=1"
  const css = doc.createElement("style")
  css.textContent = guideStyles
  doc.head.prepend(charset, csp, viewport)
  doc.head.append(css)

  function append(parent: HTMLElement, tag: string, value?: string) {
    const el = doc.createElement(tag)
    if (value !== undefined) el.textContent = value
    parent.append(el)
    return el
  }

  const main = append(doc.body, "main")
  main.className = "interviewer-guide"
  append(main, "h1", role.name)
  append(main, "p", "Interviewer guide · Revision " + revisionNumber(role.version_number, role.version_number_text))
  append(main, "h2", "Resource policy")
  append(main, "p", role.policy || "No policy recorded for this revision.")
  append(main, "h2", "Planned questions")
  if (role.questions.length) {
    const list = append(main, "ol")
    role.questions.forEach(question => append(list, "li", question))
  } else {
    append(main, "p", "No planned questions in this revision.")
  }

  if (options.rubric && role.rubric?.length) {
    append(main, "h2", "Grading rubric")
    for (const entry of role.rubric) {
      append(main, "h3", entry.criterion)
      append(main, "p", "Weight " + entry.weight)
      for (const [label, items] of [["Expected signals", entry.expected_signals], ["Red flags", entry.red_flags]] as const) {
        if (!items.length) continue
        append(main, "p", label)
        const list = append(main, "ul")
        items.forEach(item => append(list, "li", item))
      }
    }
  }
  if (options.materials && role.permitted_sources.length) {
    append(main, "h2", "Permitted materials")
    for (const material of role.permitted_sources) {
      append(main, "h3", material.label)
      append(main, "p", material.text)
    }
  }
  return doc
}
