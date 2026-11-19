import { useEffect, useId, useRef, useState } from "react"
import Link from "next/link"
import { ChevronDown, Download, FileText, Printer, Table2 } from "lucide-react"
import { Button } from "./ui/button"

const DEFAULT_OPTS = { include_sources: true, include_scorecard: true, include_handoff_notes: false, redact_candidate: false }
type PrintOptions = typeof DEFAULT_OPTS
const PRINT_FIELDS: Array<[keyof PrintOptions, string]> = [
  ["include_sources", "Include sources"], ["include_scorecard", "Include scorecard"],
  ["include_handoff_notes", "Include handoff notes"], ["redact_candidate", "Redact candidate"],
]

export function ReportExport({ sessionId, disabled = false }: { sessionId?: string; disabled?: boolean }) {
  const id = useId(), optionsId = useId()
  const rootRef = useRef<HTMLDivElement>(null), toggle = useRef<HTMLButtonElement>(null), optionsBtn = useRef<HTMLButtonElement>(null)
  const [expanded, setExpanded] = useState(false), [optionsOpen, setOptionsOpen] = useState(false)
  const [options, setOptions] = useState<PrintOptions>(DEFAULT_OPTS)

  useEffect(() => {
    if (!expanded && !optionsOpen) return
    const onPointer = (e: PointerEvent) => { if (!rootRef.current?.contains(e.target as Node)) { setExpanded(false); setOptionsOpen(false) } }
    document.addEventListener("pointerdown", onPointer)
    return () => document.removeEventListener("pointerdown", onPointer)
  }, [expanded, optionsOpen])

  if (!sessionId) {
    return <Button asChild variant="outline" size="sm"><a href="/api/exports/interviews.csv" download><Table2 />Export archive CSV</a></Button>
  }

  const base = "/api/sessions/" + encodeURIComponent(sessionId)
  const printHref = `${base}/print?${new URLSearchParams(Object.entries(options).map(([k, v]) => [k, String(v)])).toString()}`
  const panelStyle = expanded
    ? { padding: "8px 4px 2px", gap: "6px" }
    : { position: "absolute" as const, top: "calc(100% + 6px)", left: 0, zIndex: 30, minWidth: "215px", maxWidth: "calc(100vw - 32px)", padding: "10px 12px", gap: "8px", boxShadow: "0 5px 16px #101d1920" }

  return (
    <div
      ref={rootRef} className="report-exports" style={{ position: "relative" }}
      onKeyDown={(e) => {
        if (e.key !== "Escape") return
        if (optionsOpen && !expanded) { setOptionsOpen(false); optionsBtn.current?.focus(); e.stopPropagation() }
        else if (expanded) { setExpanded(false); setOptionsOpen(false); toggle.current?.focus(); e.stopPropagation() }
      }}
    >
      <Button
        ref={toggle} type="button" className="report-toggle" variant="outline" size="sm"
        disabled={disabled} aria-expanded={expanded && !disabled} aria-controls={id}
        onClick={() => { const next = !expanded; setExpanded(next); setOptionsOpen(next) }}
      ><FileText />Reports<ChevronDown /></Button>
      <div className="report-links row" id={id} data-expanded={expanded && !disabled}>
        {disabled ? <>
          <Button disabled variant="outline" size="sm"><FileText />Review brief</Button>
          <Button disabled variant="outline" size="sm" aria-label="Export report"><Download />Markdown</Button>
          <Button disabled variant="outline" size="sm"><Printer />Print or save PDF</Button>
          <Button disabled variant="outline" size="sm">Print options<ChevronDown /></Button>
        </> : <>
          <Button asChild variant="outline" size="sm"><Link href={"/interviews/brief/?id=" + encodeURIComponent(sessionId)}><FileText />Review brief</Link></Button>
          <Button asChild variant="outline" size="sm"><a href={base + "/report"} download aria-label="Export report"><Download />Markdown</a></Button>
          <Button asChild variant="outline" size="sm"><a href={printHref} target="_blank" rel="noreferrer"><Printer />Print or save PDF</a></Button>
          <Button ref={optionsBtn} type="button" variant="outline" size="sm" aria-expanded={optionsOpen} aria-controls={optionsId} onClick={() => setOptionsOpen((v) => !v)}>
            Print options<ChevronDown />
          </Button>
          {optionsOpen && (
            <div id={optionsId} role="group" aria-label="Print report options" className="notice stack" style={panelStyle}>
              {PRINT_FIELDS.map(([key, label]) => (
                <label key={key} className="check" style={{ fontSize: "13px", cursor: "pointer" }}>
                  <input type="checkbox" checked={options[key]} onChange={(e) => setOptions((prev) => ({ ...prev, [key]: e.target.checked }))} />
                  {label}
                </label>
              ))}
            </div>
          )}
        </>}
      </div>
    </div>
  )
}
export default ReportExport
