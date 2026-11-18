import { Download, Printer, Table2 } from "lucide-react"
import { Button } from "./ui/button"

export function ReportExport({ sessionId }: { sessionId?: string }) {
  if (!sessionId) return <Button asChild variant="outline" size="sm">
    <a href="/api/exports/interviews.csv" download><Table2/>Export archive CSV</a>
  </Button>
  const base = "/api/sessions/" + encodeURIComponent(sessionId)
  return <div className="row">
    <Button asChild variant="outline" size="sm">
      <a href={base + "/report"} aria-label="Export report" download><Download/>Markdown</a>
    </Button>
    <Button asChild variant="outline" size="sm">
      <a href={base + "/print"} target="_blank" rel="noreferrer"><Printer/>Print or save PDF</a>
    </Button>
  </div>
}

export default ReportExport
