import { useId, useRef, useState } from "react"
import Link from "next/link"
import { ChevronDown, Download, FileText, Printer, Table2 } from "lucide-react"
import { Button } from "./ui/button"

export function ReportExport({sessionId,disabled=false}:{sessionId?:string;disabled?:boolean}) {
  const id=useId(), toggle=useRef<HTMLButtonElement>(null)
  const [expanded,setExpanded]=useState(false)
  if(!sessionId) return <Button asChild variant="outline" size="sm"><a href="/api/exports/interviews.csv" download><Table2/>Export archive CSV</a></Button>
  const base="/api/sessions/"+encodeURIComponent(sessionId)
  return <div className="report-exports" onBlur={e=>{if(!e.currentTarget.contains(e.relatedTarget))setExpanded(false)}}
    onKeyDown={e=>{if(e.key==="Escape"&&expanded){setExpanded(false);toggle.current?.focus();e.stopPropagation()}}}>
    <Button ref={toggle} type="button" className="report-toggle" variant="outline" size="sm" disabled={disabled} aria-expanded={expanded && !disabled} aria-controls={id} onClick={()=>setExpanded(!expanded)}><FileText/>Reports<ChevronDown/></Button>
    <div className="report-links row" id={id} data-expanded={expanded && !disabled}>
      {disabled?<>
        <Button disabled variant="outline" size="sm"><FileText/>Review brief</Button>
        <Button disabled variant="outline" size="sm" aria-label="Export report"><Download/>Markdown</Button>
        <Button disabled variant="outline" size="sm"><Printer/>Print or save PDF</Button>
      </>:<>
        <Button asChild variant="outline" size="sm"><Link href={"/interviews/brief/?id="+encodeURIComponent(sessionId)}><FileText/>Review brief</Link></Button>
        <Button asChild variant="outline" size="sm"><a href={base+"/report"} download aria-label="Export report"><Download/>Markdown</a></Button>
        <Button asChild variant="outline" size="sm"><a href={base+"/print"} target="_blank" rel="noreferrer"><Printer/>Print or save PDF</a></Button>
      </>}
    </div>
  </div>
}
export default ReportExport
