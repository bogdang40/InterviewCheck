import {
  ArrowDownRight,
  ArrowRight,
  BookOpen,
  CirclePlus,
  FileSearch,
  Layers3,
  MessageSquareText,
  Plus,
  ScanText,
  Search,
} from "lucide-react"
import { useState } from "react"
import { Button } from "./ui/button"
import ReportExport from "./ReportExport"
import SignalField from "./SignalField"
import { dateLabel, type Session } from "@/lib/api"

type Props = {
  sessions: Session[]
  loaded: boolean
  archive: boolean
  onCreate: () => void
  onSample: () => void
  onOpen: (id: string) => void
}

export default function Dashboard({ sessions, loaded, archive, onCreate, onSample, onOpen }: Props) {
  const [query, setQuery] = useState("")
  const list = sessions.filter((s) =>
    (s.candidate + " " + s.role).toLowerCase().includes(query.toLowerCase()),
  )
  const stats = [
    { name: "Interviews", value: sessions.length, icon: Layers3 },
    {
      name: "Answers captured",
      value: sessions.reduce((n, s) => n + s.answer_count, 0),
      icon: MessageSquareText,
    },
    { name: "Pending review", value: sessions.reduce((n, s) => n + s.review_count, 0), icon: FileSearch },
  ]
  return (
    <>
      {!archive && (
        <section className="hero">
          <div className="hero-copy">
            <h1>Interview workspace</h1>
            <p>
              Compare interview answers with their sources and keep a record of what the candidate explains.
            </p>
            <div className="row">
              <Button onClick={onCreate}>
                <Plus />
                New interview
              </Button>
              <Button variant="ghost" className="hero-secondary" onClick={onSample}>
                Open sample <ArrowRight />
              </Button>
            </div>
          </div>
          <SignalField />
        </section>
      )}
      {archive ? (
        <div className="page-title">
          <div className="eyebrow">LIBRARY</div>
          <h1>Interviews</h1>
          <p>Open a session to review its evidence or export the report.</p>
        </div>
      ) : (
        <div className="stats">
          {stats.map(({ name, value, icon: Icon }) => (
            <div className="stat" key={name}>
              <div>
                <span className="small-label">{name}</span>
                <strong>{loaded ? String(value).padStart(2, "0") : "··"}</strong>
              </div>
              <Icon size={19} />
            </div>
          ))}
        </div>
      )}
      <div className={archive ? "" : "overview-grid"}>
        <section className="panel sessions-panel">
          <div className="panel-head">
            <div>
              <h2>{archive ? "All interviews" : "Recent interviews"}</h2>
            </div>
            {archive && (
              <div className="row">
                <ReportExport />
                <Button size="sm" onClick={onCreate}>
                  <Plus />
                  New interview
                </Button>
              </div>
            )}
          </div>
          {(archive || sessions.length > 5) && (
            <label className="search">
              <Search size={16} />
              <input
                aria-label="Search interviews"
                placeholder="Search candidate or role"
                value={query}
                onChange={(e) => setQuery(e.target.value)}
              />
            </label>
          )}
          <div className="session-head">
            <span>Candidate / role</span>
            <span>Review</span>
          </div>
          {list.slice(0, archive ? undefined : 5).map((s) => (
            <button className="session-entry" key={s.id} onClick={() => onOpen(s.id)}>
              <span className="session-avatar">{(s.candidate || "I").slice(0, 1).toUpperCase()}</span>
              <span className="entry-copy">
                <b>{s.candidate || "Untitled interview"}</b>
                <small>
                  {s.role || "Role unspecified"} · {dateLabel(s.created_at)}
                </small>
              </span>
              <span className="entry-state">
                {s.review_count ? `${s.review_count} pending` : s.ended_at ? "Finished" : "In progress"} <ArrowRight size={14} />
              </span>
            </button>
          ))}
          {!list.length && (
            <div className="empty">
              <div className="empty-icon">
                <Layers3 size={23} />
              </div>
              <strong>
                {!loaded
                  ? "Loading interviews"
                  : query
                    ? "No matching interviews"
                    : "Your session log is empty"}
              </strong>
              <p>
                {query
                  ? "Try another candidate name or role."
                  : "Saved interviews and their evidence appear here."}
              </p>
              {loaded && !query && (
                <Button variant="outline" size="sm" onClick={onCreate}>
                  <CirclePlus />
                  Create interview
                </Button>
              )}
            </div>
          )}
        </section>
        {!archive && (
          <aside className="panel method">
            <div className="panel-head">
              <div>
                <h2>Review method</h2>
              </div>
              <BookOpen size={19} />
            </div>
            <div className="method-item">
              <ScanText />
              <div>
                <strong>Compare wording</strong>
                <p>Inspect matched passages against named references.</p>
              </div>
            </div>
            <div className="method-item">
              <ArrowDownRight />
              <div>
                <strong>Test the reasoning</strong>
                <p>Change a constraint and ask the candidate to explain.</p>
              </div>
            </div>
            <button className="text-action" onClick={onSample}>
              Explore a sample review <ArrowRight size={15} />
            </button>
          </aside>
        )}
      </div>
    </>
  )
}
