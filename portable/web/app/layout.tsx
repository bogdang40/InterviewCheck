import Script from "next/script"
import WorkspaceShell from "@/components/WorkspaceShell"
import type { Metadata } from "next"
import "@fontsource-variable/dm-sans/wght.css"
import "@fontsource/instrument-serif/latin-400-italic.css"
import "@fontsource/ibm-plex-mono/latin-400.css"
import "./globals.css"
import "./shell.css"
import "./overview.css"
import "./forms.css"
import "./responsive.css"
import "./workbench.css"
import "./workspace-chrome.css"
import "./workspace-data.css"
import "./workspace-search.css"
import "./report-controls.css"
import "./theme.css"
import "./studio.css"

export const metadata: Metadata = {
  title: "InterviewCheck | Workspace",
  description: "Review interview answers against their sources.",
}

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" data-theme="dark" suppressHydrationWarning>
      <head><Script src="/appearance.js" strategy="beforeInteractive"/></head>
      <body>
        <WorkspaceShell>{children}</WorkspaceShell>
      </body>
    </html>
  )
}
