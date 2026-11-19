export type ThemePreference = "light" | "dark" | "system"
export type CommandKind = "navigation" | "theme" | "help"

export type PaletteCommand = {
  id: string
  label: string
  description: string
  kind: CommandKind
  keywords: string[]
  href?: string
  theme?: ThemePreference
  shortcut?: string
  adminOnly?: boolean
}

export const PALETTE_COMMANDS: readonly PaletteCommand[] = [
  { id: "nav-overview", label: "Go to Overview", description: "Workspace dashboard and pending review queue", kind: "navigation", href: "/", keywords: ["home", "dashboard", "queue", "overview"] },
  { id: "nav-interviews", label: "Go to Interviews", description: "Browse and filter recorded interviews", kind: "navigation", href: "/interviews/", keywords: ["sessions", "archive", "records", "interviews"] },
  { id: "nav-compare", label: "Compare candidates", description: "Side-by-side candidate matrix and comparison dossier", kind: "navigation", href: "/interviews/compare/", keywords: ["compare", "candidates", "matrix", "dossier"] },
  { id: "nav-new-interview", label: "New interview", description: "Prepare and start a new interview session", kind: "navigation", href: "/interviews/new/", keywords: ["create", "start", "setup", "new", "interview"] },
  { id: "nav-roles", label: "Go to Role library", description: "Manage role templates, questions, and rubrics", kind: "navigation", href: "/roles/", keywords: ["roles", "templates", "rubric", "library"] },
  { id: "nav-connections", label: "Go to Connections", description: "Configure provider and ATS integrations", kind: "navigation", href: "/connections/", keywords: ["integrations", "providers", "ats", "connections"] },
  { id: "nav-data", label: "Go to Data", description: "Backups, appearance theme, and workspace trash", kind: "navigation", href: "/data/", keywords: ["backup", "export", "trash", "data", "appearance"] },
  { id: "nav-account", label: "Go to Account", description: "Manage sign-in session, passwords, and API tokens", kind: "navigation", href: "/account/", keywords: ["profile", "session", "tokens", "security", "account"] },
  { id: "nav-admin", label: "Go to Model admin", description: "Manage connected models, telemetry, and admin console", kind: "navigation", href: "/admin/", keywords: ["admin", "models", "audit", "telemetry", "security"], adminOnly: true },
  { id: "theme-light", label: "Switch theme: Light", description: "Apply the light color theme in this browser", kind: "theme", theme: "light", keywords: ["appearance", "color", "bright", "day", "light", "theme"] },
  { id: "theme-dark", label: "Switch theme: Dark", description: "Apply the dark color theme in this browser", kind: "theme", theme: "dark", keywords: ["appearance", "color", "night", "dark", "theme"] },
  { id: "theme-system", label: "Switch theme: System", description: "Follow your operating system color preference", kind: "theme", theme: "system", keywords: ["appearance", "os", "auto", "system", "theme"] },
  { id: "help-shortcuts", label: "Open keyboard shortcuts", description: "View workspace, palette, and workbench keyboard shortcuts", kind: "help", shortcut: "?", keywords: ["help", "keys", "hotkeys", "shortcuts", "?"] },
]

export function getAvailableCommands(isAdmin: boolean): PaletteCommand[] {
  return PALETTE_COMMANDS.filter((cmd) => !cmd.adminOnly || isAdmin)
}

export function filterPaletteCommands(query: string, isAdmin: boolean): PaletteCommand[] {
  const available = getAvailableCommands(isAdmin)
  const normalized = query.trim().toLowerCase()
  if (!normalized) return available
  const tokens = normalized.split(/\s+/).filter(Boolean)
  const matches: Array<{ cmd: PaletteCommand; rank: number; order: number }> = []
  available.forEach((cmd, order) => {
    const label = cmd.label.toLowerCase()
    const haystack = `${label} ${cmd.description.toLowerCase()} ${cmd.href ?? ""} ${cmd.keywords.join(" ").toLowerCase()}`
    if (!tokens.every((token) => haystack.includes(token))) return
    const rank = label.startsWith(normalized) ? 0 : label.includes(normalized) ? 1 : 2
    matches.push({ cmd, rank, order })
  })
  matches.sort((a, b) => a.rank - b.rank || a.order - b.order)
  return matches.map((entry) => entry.cmd)
}

export function applyThemePreference(preference: ThemePreference): void {
  if (typeof document === "undefined") return
  document.documentElement.dataset.theme = preference
  try {
    localStorage.setItem("interviewcheck.appearance", preference)
  } catch {
    /* Applies for the current page if storage is unavailable. */
  }
  if (typeof window !== "undefined") {
    window.dispatchEvent(new Event("interviewcheck:appearance"))
  }
}

export function isEditableTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false
  if (target.isContentEditable) return true
  return Boolean(target.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"])'))
}

export function hasOpenModalDialog(): boolean {
  if (typeof document === "undefined") return false
  return Boolean(document.querySelector('dialog[open], [role="dialog"][aria-modal="true"]'))
}
