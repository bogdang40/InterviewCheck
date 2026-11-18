import { Download, Printer, Table2 } from "lucide-react"
import { Button } from "./ui/button"

export function ReportExport({ sessionId, disabled = false }: { sessionId?: string; disabled?: boolean }) {
  if (!sessionId)
    return (
      <Button asChild variant="outline" size="sm">
        <a href="/api/exports/interviews.csv" download>
          <Table2 />
          Export archive CSV
        </a>
      </Button>
    )
  if (disabled)
    return (
      <div className="row">
        <Button disabled variant="outline" size="sm" aria-label="Export report">
          <Download />
          Markdown
        </Button>
        <Button disabled variant="outline" size="sm">
          <Printer />
          Print or save PDF
        </Button>
      </div>
    )
  const base = "/api/sessions/" + encodeURIComponent(sessionId)
  return (
    <div className="row">
      <Button asChild variant="outline" size="sm">
        <a href={base + "/report"} aria-label="Export report" download>
          <Download />
          Markdown
        </a>
      </Button>
      <Button asChild variant="outline" size="sm">
        <a href={base + "/print"} target="_blank" rel="noreferrer">
          <Printer />
          Print or save PDF
        </a>
      </Button>
    </div>
  )
}

export default ReportExport
