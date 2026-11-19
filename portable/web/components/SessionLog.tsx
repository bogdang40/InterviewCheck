import Link from "next/link"
import { ArrowRight, BookOpen, Cable, ChevronRight, FileAudio, FolderOpen } from "lucide-react"
import { Card, CardHeader } from "./ui/card"

export default function SessionLog() {
  return <div className="start-panels">
    <Card asChild className="log-card">
      <section aria-labelledby="log-title">
        <CardHeader><h2 id="log-title">Session log</h2><Link href="/interviews/" className="queue-link">Archive <ArrowRight size={14}/></Link></CardHeader>
        <div className="log-empty">
          <span className="log-symbol" aria-hidden="true"><FileAudio size={26} strokeWidth={1.4}/></span>
          <h3>Your session log is empty</h3>
          <p>Start an interview to save its questions, sources and review notes here.</p>
        </div>
      </section>
    </Card>
    <Card asChild className="prep-card">
      <section aria-labelledby="prep-title">
        <CardHeader><h2 id="prep-title">Preparation</h2><FolderOpen size={18} aria-hidden="true"/></CardHeader>
        <Link href="/roles/"><BookOpen/><span><strong>Choose a role template</strong><small>Questions and permitted sources</small></span><ChevronRight/></Link>
        <Link href="/connections/"><Cable/><span><strong>Set up connections</strong><small>Calendars, recordings and candidate imports</small></span><ChevronRight/></Link>
      </section>
    </Card>
  </div>
}
