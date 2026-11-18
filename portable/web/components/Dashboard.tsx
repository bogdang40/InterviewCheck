import Link from "next/link"
import { ArrowRight, ClipboardList, FolderOpen, Plus } from "lucide-react"
import { Button } from "./ui/button"
import SignalField from "./SignalField"
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
    <section className="hero queue-hero">
      <div className="hero-copy">
        <h1>Interview workspace</h1>
        <p>{populated
          ? `${activeCount} active ${activeCount === 1 ? "interview" : "interviews"} · ${pendingAnswers} ${pendingAnswers === 1 ? "answer" : "answers"} pending review`
          : "Capture interview answers, compare sources and record the candidate’s explanation."}</p>
        <div className="row">
          <Button onClick={onCreate}><Plus/>New interview</Button>
          <Button variant="ghost" className="hero-secondary" onClick={onSample}>Open sample <ArrowRight/></Button>
        </div>
      </div>
      <SignalField/>
    </section>
    {!overview ? <p className="queue-loading" role="status">Loading interviews…</p>
      : !populated ? <section className="panel queue-empty-start" aria-labelledby="start-log">
        <div className="queue-illustration"><ClipboardList size={26}/></div>
        <div><h2 id="start-log">Your session log is empty</h2>
          <p>Start an interview to collect its questions, sources and follow up notes in one place.</p></div>
      </section> : <>
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
        <p className="archive-total"><FolderOpen size={15}/>
          {total} {total === 1 ? "interview" : "interviews"} in this workspace</p>
      </>}
  </div>
}
