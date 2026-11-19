"use client"

import Link from "next/link"
import { usePathname, useRouter } from "next/navigation"
import { useEffect, useId, useRef, useState } from "react"
import { ArrowLeft, ChevronRight, LayoutGrid, Menu, UserRound } from "lucide-react"
import { blankPreparation, interviewURL, PreparationContext, type Preparation } from "@/lib/workspace"
import { useAccountStatus } from "@/lib/useAccountStatus"
import { WorkspaceNav, workspaceMenu } from "./WorkspaceNav"
import WorkspaceSearch from "./WorkspaceSearch"

const pages: Record<string, string> = Object.fromEntries(workspaceMenu.map((item) => [item.path, item.label]))
Object.assign(pages, {
  "/interviews/new/": "New interview",
  "/interviews/review/": "Interview record",
  "/interviews/brief/": "Review brief",
  "/interviews/compare/": "Compare candidates",
  "/sample/": "Sample review",
  "/trash/": "Trash",
  "/account/": "Account",
  "/admin/": "Model admin",
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
  const [drawerOpen, setDrawerOpen] = useState(false)
  const [isMobile, setIsMobile] = useState(false)
  const drawerId = useId()
  const toggleRef = useRef<HTMLButtonElement>(null)
  const closeRef = useRef<HTMLButtonElement>(null)
  const drawerRef = useRef<HTMLElement>(null)
  const shouldRestoreFocusRef = useRef(false)
  const { account, isAdmin } = useAccountStatus(path)
  const showAdminNav = isAdmin || path.startsWith("/admin/")
  const pageTitle = pages[path] ?? (path.startsWith("/admin/") ? "Model admin" : "Page")

  function prepare(input = blankPreparation) {
    setPreparation(input)
    router.push("/interviews/new/")
  }

  useEffect(() => {
    const mq = window.matchMedia("(max-width: 820px)")
    const sync = () => {
      setIsMobile(mq.matches)
      if (!mq.matches) setDrawerOpen(false)
    }
    sync()
    mq.addEventListener("change", sync)
    return () => mq.removeEventListener("change", sync)
  }, [])

  useEffect(() => {
    setDrawerOpen(false)
  }, [path])

  useEffect(() => {
    document.body.classList.toggle("drawer-open", drawerOpen && isMobile)
    if (!drawerOpen || !isMobile) {
      if (!drawerOpen && shouldRestoreFocusRef.current) {
        shouldRestoreFocusRef.current = false
        toggleRef.current?.focus()
      }
      return
    }
    closeRef.current?.focus()
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") {
        shouldRestoreFocusRef.current = true
        setDrawerOpen(false)
        return
      }
      if (e.key !== "Tab") return
      const drawer = drawerRef.current
      if (!drawer) return
      const focusable = Array.from(
        drawer.querySelectorAll<HTMLElement>(
          'a[href], button:not(:disabled), input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [tabindex]:not([tabindex="-1"])',
        ),
      ).filter((el) => {
        if (el.closest("[inert], [hidden]")) return false
        const cs = window.getComputedStyle(el)
        return cs.display !== "none" && cs.visibility !== "hidden"
      })
      if (focusable.length === 0) {
        e.preventDefault()
        return
      }
      const first = focusable[0]
      const last = focusable[focusable.length - 1]
      const active = document.activeElement as HTMLElement | null
      if (!active || !drawer.contains(active)) {
        e.preventDefault()
        ;(e.shiftKey ? last : first).focus()
        return
      }
      if (e.shiftKey && active === first) {
        e.preventDefault()
        last.focus()
      } else if (!e.shiftKey && active === last) {
        e.preventDefault()
        first.focus()
      }
    }
    window.addEventListener("keydown", onKey)
    return () => {
      window.removeEventListener("keydown", onKey)
      document.body.classList.remove("drawer-open")
    }
  }, [drawerOpen, isMobile])

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

  const backgroundInert = isMobile && drawerOpen ? true : undefined

  function closeDrawer(restoreFocus = true) {
    if (restoreFocus) shouldRestoreFocusRef.current = true
    setDrawerOpen(false)
  }

  return (
    <PreparationContext.Provider value={{ preparation, prepare }}>
      <div className="shell">
        <a href="#main-content" className="skip-content" inert={backgroundInert}>
          Skip to content
        </a>
        {drawerOpen && isMobile && (
          <div className="drawer-backdrop" onClick={() => closeDrawer(true)} aria-hidden="true" />
        )}
        <WorkspaceNav
          path={path}
          drawerId={drawerId}
          drawerOpen={drawerOpen}
          isMobile={isMobile}
          showAdminNav={showAdminNav}
          account={account}
          closeRef={closeRef}
          drawerRef={drawerRef}
          onClose={() => closeDrawer(true)}
          onNavigate={() => closeDrawer(false)}
        />
        <main className="main" id="main-content" tabIndex={-1} inert={backgroundInert}>
          <header className="top">
            <div className="top-left">
              <button
                ref={toggleRef}
                type="button"
                className="nav-toggle"
                aria-label="Open navigation menu"
                aria-expanded={drawerOpen}
                aria-controls={drawerId}
                onClick={() => setDrawerOpen(true)}
              >
                <Menu size={20} aria-hidden="true" />
              </button>
              <nav className="breadcrumb" aria-label="Breadcrumb">
                <LayoutGrid size={15} className="breadcrumb-icon" aria-hidden="true" />
                <Link href="/" className="breadcrumb-root">
                  Workspace
                </Link>
                <ChevronRight size={13} className="breadcrumb-sep" aria-hidden="true" />
                <b>{pageTitle}</b>
              </nav>
            </div>
            <div className="header-tools">
              <WorkspaceSearch isAdmin={isAdmin} />
              <Link className="account-link" href="/account/" aria-label="Account">
                <UserRound size={16} aria-hidden="true" />
                <span>Account</span>
              </Link>
            </div>
          </header>
          <div className="content content-enter" key={path}>
            {path.startsWith("/interviews/") && path !== "/interviews/" && (
              <Link className="back" href="/interviews/">
                <ArrowLeft size={14} aria-hidden="true" />
                Interviews
              </Link>
            )}
            {children}
          </div>
        </main>
      </div>
    </PreparationContext.Provider>
  )
}
