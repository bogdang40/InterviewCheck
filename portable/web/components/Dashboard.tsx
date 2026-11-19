import Link from "next/link"
import { ArrowRight, Plus } from "lucide-react"
import { Button } from "./ui/button"
import SignalField from "./SignalField"
import WorkspaceMetrics from "./WorkspaceMetrics"
import SessionLog from "./SessionLog"
import SessionRow from "./SessionRow"
import type { Overview } from "@/lib/interview-list"

type Props = {
  overview: Overview | null
  onCreate: () => void
  onSample: () => void
  onOpen: (id: string) => void
}

export default function Dashboard({ overview, onCreate, onSample, onOpen }: Props) {
  const active = overview?.active ?? []
  const pending = overview?.pending ?? []
  const pendingAnswers = overview?.pending_count ?? 0
  const pendingSessions = overview?.pending_sessions ?? 0
  const total = overview?.total ?? 0
  const activeCount = overview?.active_count ?? 0
  const populated = total > 0

  return <div className={"queue-home" + (populated ? " populated" : "")}>
    <section className="studio-hero" aria-labelledby="workspace-heading">
      <div className="studio-copy">
        <h1 id="workspace-heading">Interview <em>workspace</em></h1>
        {!populated && <p>Capture interview answers, compare sources and record the candidate’s explanation.</p>}
        <div className="studio-actions">
          <Button onClick={onCreate}><Plus aria-hidden="true"/>New interview</Button>
          <Button variant="ghost" onClick={onSample}>Open sample <ArrowRight aria-hidden="true"/></Button>
        </div>
      </div>
      <div className="studio-art" aria-hidden="true">
        <SignalField/>
        <img src="/studio-microphone.webp" alt="" width="830" height="850" fetchPriority="high"/>
      </div>
    </section>
    {!overview ? <section className="panel inset" role="status" aria-live="polite"><p className="queue-loading">Loading interviews…</p></section> : <>
      <WorkspaceMetrics overview={overview}/>
      {!populated ? <>
        <section className="panel stack" aria-labelledby="empty-workspace-heading">
          <div className="queue-head">
            <div>
              <h2 id="empty-workspace-heading">Get started</h2>
              <p>Review existing interviews or configure role rubrics before capturing a new session.</p>
            </div>
          </div>
          <div className="row">
            <Button asChild variant="outline"><Link href="/interviews/">Open interviews</Link></Button>
            <Button asChild variant="outline"><Link href="/roles/">Manage roles</Link></Button>
          </div>
        </section>
        <SessionLog/>
      </> : <>
        <section className="panel queue-panel" aria-labelledby="pending-heading">
          <div className="queue-head"><div><h2 id="pending-heading">Review queue</h2>
            <p>{pendingAnswers ? `${pendingAnswers} pending ${pendingAnswers === 1 ? "match" : "matches"} across ${pendingSessions} ${pendingSessions === 1 ? "interview" : "interviews"}`
              : "No passage matches are waiting for review."}</p></div>
            {pending.length > 0 && <Link className="queue-link" href="/interviews/?review=pending&sort=pending">
              View all pending <ArrowRight size={15}/></Link>}
          </div>
          {pending.length > 0 && <ul className="work-list pending-rows">{pending.map(s =>
            <li key={s.id}><SessionRow session={s} review/></li>)}</ul>}
          {pendingSessions > pending.length && <p className="queue-cap">Showing the first {pending.length} interviews with the most pending matches.</p>}
        </section>
        <section className="panel queue-panel" aria-labelledby="active-heading">
          <div className="queue-head"><div><h2 id="active-heading">Active interviews</h2>
            <p>{active.length ? "Resume capture or add an exchange." : "No interviews are in progress."}</p></div>
            <Link className="queue-link" href="/interviews/">Interview archive <ArrowRight size={15}/></Link>
          </div>
          {active.length > 0 && <ul className="work-list">{active.map(s =>
            <li key={s.id}><SessionRow session={s} resume={() => onOpen(s.id)}/></li>)}</ul>}
          {activeCount > active.length && <Link className="queue-more" href="/interviews/?status=active">View all {activeCount} active interviews <ArrowRight size={14}/></Link>}
        </section>
      </>}
    </>}
  </div>
}
