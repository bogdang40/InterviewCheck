"use client"

import WorkspaceSearch from "./WorkspaceSearch"
import Link from "next/link"
import { usePathname, useRouter } from "next/navigation"
import { useEffect, useState } from "react"
import {
  BriefcaseBusiness,
  ChevronRight,
  CircleHelp,
  UserRound,
  FolderClock,
  LayoutGrid,
  Plug,
  AudioLines,
  Database,
  ArrowLeft,
} from "lucide-react"
import { MotionConfig, motion } from "framer-motion"
import { blankPreparation, interviewURL, PreparationContext, type Preparation } from "@/lib/workspace"

const menu = [
  { path: "/", label: "Overview", icon: LayoutGrid },
  { path: "/interviews/", label: "Interviews", icon: FolderClock },
  { path: "/roles/", label: "Role library", icon: BriefcaseBusiness },
  { path: "/connections/", label: "Connections", icon: Plug },
  { path: "/data/", label: "Data", icon: Database },
]
const pages: Record<string, string> = Object.fromEntries(menu.map((item) => [item.path, item.label]))
Object.assign(pages, {
  "/interviews/new/": "New interview",
  "/interviews/review/": "Interview record",
  "/interviews/brief/": "Review brief",
  "/sample/": "Sample review",
  "/trash/": "Trash",
  "/account/": "Account",
})
const bookmarks: Record<string, string> = {
  overview: "/",
  interviews: "/interviews/",
  roles: "/roles/",
  connections: "/connections/",
  new: "/interviews/new/",
  sample: "/sample/",
}

export default function WorkspaceShell({ children }: { children: React.ReactNode }) {
  const router = useRouter()
  const pathname = usePathname()
  const path = pathname === "/" ? "/" : pathname.replace(/\/?$/, "/")
  const [preparation, setPreparation] = useState<Preparation>(blankPreparation)
  function prepare(input = blankPreparation) {
    setPreparation(input)
    router.push("/interviews/new/")
  }
  useEffect(() => {
    function restoreBookmark() {
      if (window.location.pathname !== "/") return
      const old = window.location.hash.slice(1)
      const session = /^session\/([\da-f-]{36})$/i.exec(old)
      const target = session ? interviewURL(session[1]) : bookmarks[old]
      if (target) router.replace(target)
    }
    restoreBookmark()
    window.addEventListener("hashchange", restoreBookmark)
    return () => window.removeEventListener("hashchange", restoreBookmark)
  }, [router, pathname])
  return (
    <PreparationContext.Provider value={{ preparation, prepare }}>
      <MotionConfig reducedMotion="user">
        <div className="shell">
          <a href="#main-content" className="skip-content">Skip to content</a>
          <aside className="sidebar">
            <Link className="brand" href="/" aria-label="InterviewCheck overview">
              <span className="brand-mark">
                <AudioLines size={24} strokeWidth={2.4} />
              </span>
              Interview<span className="brand-light">Check</span>
            </Link>
            <div className="mobile-tools"><WorkspaceSearch compact/><Link className="mobile-account" href="/account/"><UserRound size={15}/>Account</Link></div>
            <span className="side-caption">WORKSPACE</span>
            <nav aria-label="Workspace">
              {menu.map(({ path: href, label, icon: Icon }) => (
                <Link
                  key={href}
                  href={href}
                  aria-current={
                    path === href || (href === "/interviews/" && path.startsWith(href)) ? "page" : undefined
                  }
                >
                  <Icon />
                  {label}
                </Link>
              ))}
            </nav>
            <div className="sidebar-foot">
              <Link href="/sample/">
                <CircleHelp size={17} />
                Sample review
              </Link>
            </div>
          </aside>
          <main className="main" id="main-content" tabIndex={-1}>
            <header className="top">
              <div className="breadcrumb">
                <LayoutGrid size={15} />
                <Link href="/">Workspace</Link>
                <ChevronRight size={13} />
                <b>{pages[path] ?? "Page"}</b>
              </div>
              <div className="header-tools"><WorkspaceSearch/><Link className="row" href="/account/"><UserRound size={16}/>Account</Link></div>
            </header>
            <motion.div
              className="content"
              key={path}
              initial={{ opacity: 0.7, y: 4 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.18 }}
            >
              {path.startsWith("/interviews/") && path !== "/interviews/" && (
                <Link className="back" href="/interviews/">
                  <ArrowLeft size={14} />
                  Interviews
                </Link>
              )}
              {children}
            </motion.div>
          </main>
        </div>
      </MotionConfig>
    </PreparationContext.Provider>
  )
}
