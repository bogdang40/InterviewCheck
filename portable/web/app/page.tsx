"use client"

import { useCallback, useEffect, useState } from "react"
import {
  ArrowLeft,
  AudioLines,
  BriefcaseBusiness,
  ChevronRight,
  CircleHelp,
  FolderClock,
  LayoutGrid,
  Monitor,
  Plug,
  Radio,
  RefreshCw,
} from "lucide-react"
import { MotionConfig, motion } from "framer-motion"
import { api, message, type Answer, type Interview, type Role, type Session } from "@/lib/api"
import Dashboard from "@/components/Dashboard"
import SessionSetup from "@/components/SessionSetup"
import InterviewView from "@/components/InterviewView"
import Migration from "@/components/Migration"
import Roles from "@/components/Roles"
import Connections from "@/components/Connections"
import Sample from "@/components/Sample"
import { Button } from "@/components/ui/button"

const navigation = [
  { id: "overview", title: "Overview", icon: LayoutGrid },
  { id: "interviews", title: "Interviews", icon: FolderClock },
  { id: "roles", title: "Role library", icon: BriefcaseBusiness },
  { id: "connections", title: "Connections", icon: Plug },
]
const valid = new Set([...navigation.map((n) => n.id), "new", "sample"])
function route() {
  const hash = window.location.hash.slice(1)
  return valid.has(hash) || /^session\/[\w-]+$/.test(hash) ? hash : "overview"
}
function go(id: string) {
  window.location.hash = id
}
const titles: Record<string, string> = {
  overview: "Overview",
  interviews: "Interviews",
  roles: "Role library",
  connections: "Connections",
  new: "New interview",
  sample: "Sample review",
  session: "Interview record",
}

export default function Workspace() {
  const [path, setPath] = useState("overview")
  const [sessions, setSessions] = useState<Session[]>([]),
    [roles, setRoles] = useState<Role[]>([])
  const [session, setSession] = useState<Interview | null>(null)
  const [error, setError] = useState(""),
    [loadError, setLoadError] = useState("")
  const [loaded, setLoaded] = useState(false),
    [retry, setRetry] = useState(0)
  const [prepare, setPrepare] = useState({ candidate: "", role: "" })
  const page = path.split("/")[0]
  useEffect(() => {
    const sync = () => {
      setPath(route())
      window.scrollTo(0, 0)
    }
    sync()
    window.addEventListener("hashchange", sync)
    return () => window.removeEventListener("hashchange", sync)
  }, [])
  useEffect(() => {
    if (page === "connections") return
    let active = true
    setError("")
    setLoaded(false)
    Promise.all([api<Session[]>("sessions"), api<Role[]>("roles")])
      .then(([s, r]) => {
        if (active) {
          setSessions(s)
          setRoles(r)
          setLoaded(true)
        }
      })
      .catch((e) => {
        if (active) setError(message(e))
      })
    return () => {
      active = false
    }
  }, [page, retry])
  useEffect(() => {
    if (page !== "session") return
    let active = true
    setLoadError("")
    api<Interview>("sessions/" + path.split("/")[1])
      .then((s) => {
        if (active) setSession(s)
      })
      .catch((e) => {
        if (active) setLoadError(message(e))
      })
    return () => {
      active = false
    }
  }, [path, page, retry])
  const newSession = useCallback((candidate = "", role = "") => {
    setPrepare({ candidate, role })
    go("new")
  }, [])
  function updateAnswer(id: string, item: Answer) {
    setSession(previous => {
      if (!previous || previous.id !== id) return previous
      const answers = previous.answers.some(answer => answer.id === item.id)
        ? previous.answers.map(answer => answer.id === item.id ? item : answer)
        : [...previous.answers, item]
      return {
        ...previous, answers, answer_count: answers.length,
        review_count: answers.filter(a => a.result.status === "match" && a.disposition === "pending").length,
      }
    })
  }
  function start(s: Interview) {
    setSession(s)
    go("session/" + s.id)
  }
  return (
    <MotionConfig reducedMotion="user">
      <div className="shell">
        <aside className="sidebar">
          <a className="brand" href="#overview" aria-label="InterviewCheck overview">
            <span className="brand-mark">
              <AudioLines size={24} strokeWidth={2.4} />
            </span>
            Interview<span className="brand-light">Check</span>
          </a>
          <span className="side-caption">WORKSPACE</span>
          <nav aria-label="Workspace">
            {navigation.map(({ id, title, icon: Icon }) => (
              <a
                key={id}
                aria-current={page === id || (id === "interviews" && page === "session") ? "page" : undefined}
                href={"#" + id}
              >
                <Icon />
                {title}
              </a>
            ))}
          </nav>
          <div className="sidebar-foot">
            <a href="#sample">
              <CircleHelp size={17} />
              Sample review
            </a>
            <div className="station">
              <span className="station-icon">
                <Monitor size={18} />
              </span>
              <div>
                <strong>Local workstation</strong>
                <small>Portable edition</small>
              </div>
            </div>
          </div>
        </aside>
        <main className="main">
          <header className="top">
            <div className="breadcrumb">
              <LayoutGrid size={15} />
              <a href="#overview">Workspace</a>
              <ChevronRight size={13} />
              <b>{titles[page]}</b>
            </div>
            <span className="host-label">
              <Radio size={14} /> Local workspace
            </span>
          </header>
          <motion.div
            key={path}
            className="content"
            initial={{ opacity: 0.7, y: 4 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.18 }}
          >
            {["new", "session", "sample"].includes(page) && (
              <a className="back" href={page === "sample" ? "#overview" : "#interviews"}>
                <ArrowLeft size={14} /> {page === "sample" ? "Overview" : "Interviews"}
              </a>
            )}
            {error && page !== "connections" && (
              <div className="error row" role="alert">
                {error}
                <Button size="sm" variant="outline" onClick={() => setRetry((x) => x + 1)}>
                  <RefreshCw />
                  Retry
                </Button>
                <a href="#connections">Connections</a>
              </div>
            )}
            {(page === "overview" || page === "interviews") && (
              <Dashboard
                sessions={sessions}
                loaded={loaded}
                archive={page === "interviews"}
                onCreate={() => newSession()}
                onSample={() => go("sample")}
                onOpen={(id) => go("session/" + id)}
              />
            )}
            {page === "new" && <SessionSetup roles={roles} {...prepare} onStart={start} />}
            {page === "roles" && (
              <div className="stack">
                <Roles
                  roles={roles}
                  onSave={(r) => setRoles((old) => [r, ...old.filter((o) => o.id !== r.id)])}
                  prepare={(r) => newSession("", r)}
                />
                <Migration onImported={() => setRetry((n) => n + 1)} />
              </div>
            )}
            {page === "connections" && (
              <>
                <div className="page-title">
                  <span className="eyebrow">WORKSPACE SETTINGS</span>
                  <h1>Connections</h1>
                  <p>Prepare interviews from connected systems and manage access to this workstation.</p>
                </div>
                <Connections onPrepare={newSession} />
              </>
            )}
            {page === "session" &&
              (loadError ? (
                <div className="error" role="alert">
                  {loadError} <Button onClick={() => setRetry((n) => n + 1)}>Retry</Button>
                </div>
              ) : session?.id === path.split("/")[1] ? (
                <InterviewView session={session} roles={roles} changed={updateAnswer} />
              ) : (
                <p role="status">Loading interview…</p>
              ))}
            {page === "sample" && <Sample create={() => newSession()} />}
          </motion.div>
        </main>
      </div>
    </MotionConfig>
  )
}
