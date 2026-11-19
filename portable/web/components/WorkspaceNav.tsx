"use client"

import Link from "next/link"
import type { RefObject } from "react"
import {
  AudioLines,
  BriefcaseBusiness,
  CirclePlay,
  Database,
  FolderClock,
  LayoutGrid,
  Plug,
  ShieldCheck,
  X,
} from "lucide-react"
import type { AccountSnapshot } from "@/lib/useAccountStatus"

export const workspaceMenu = [
  { path: "/", label: "Overview", icon: LayoutGrid },
  { path: "/interviews/", label: "Interviews", icon: FolderClock },
  { path: "/roles/", label: "Role library", icon: BriefcaseBusiness },
  { path: "/connections/", label: "Connections", icon: Plug },
  { path: "/data/", label: "Data", icon: Database },
]

export function WorkspaceNav({
  path,
  drawerId,
  drawerOpen,
  isMobile,
  showAdminNav,
  account,
  closeRef,
  drawerRef,
  onClose,
}: {
  path: string
  drawerId: string
  drawerOpen: boolean
  isMobile: boolean
  showAdminNav: boolean
  account: AccountSnapshot | null
  closeRef: RefObject<HTMLButtonElement | null>
  drawerRef?: RefObject<HTMLElement | null>
  onClose: () => void
}) {
  const statusLabel = account?.admin ? "Admin session" : account ? "Signed in" : "Local workspace"

  return (
    <aside
      ref={drawerRef}
      id={drawerId}
      className={drawerOpen ? "sidebar open" : "sidebar"}
      aria-label={isMobile ? "Workspace navigation" : undefined}
      aria-hidden={isMobile && !drawerOpen ? true : undefined}
      inert={isMobile && !drawerOpen}
    >
      <div className="sidebar-head">
        <Link className="brand" href="/" aria-label="InterviewCheck overview" onClick={onClose}>
          <span className="brand-mark">
            <AudioLines size={22} strokeWidth={2.4} />
          </span>
          Interview<span className="brand-light">Check</span>
        </Link>
        <button
          ref={closeRef}
          type="button"
          className="nav-close"
          aria-label="Close navigation menu"
          onClick={onClose}
        >
          <X size={18} />
        </button>
      </div>
      <span className="side-caption">WORKSPACE</span>
      <nav aria-label="Workspace">
        {workspaceMenu.map(({ path: href, label, icon: Icon }) => (
          <Link
            key={href}
            href={href}
            aria-label={label}
            onClick={onClose}
            aria-current={
              path === href || (href === "/interviews/" && path.startsWith(href)) ? "page" : undefined
            }
          >
            <Icon size={17} />
            <span>{label}</span>
          </Link>
        ))}
        {showAdminNav && (
          <Link
            href="/admin/"
            aria-label="Admin"
            onClick={onClose}
            aria-current={path.startsWith("/admin/") ? "page" : undefined}
          >
            <ShieldCheck size={17} />
            <span>Admin</span>
          </Link>
        )}
      </nav>
      <div className="sidebar-foot">
        <Link
          href="/sample/"
          onClick={onClose}
          aria-current={path === "/sample/" ? "page" : undefined}
        >
          <CirclePlay size={17} />
          <span>Sample review</span>
        </Link>
        <p className="session-pill">{statusLabel}</p>
      </div>
    </aside>
  )
}
