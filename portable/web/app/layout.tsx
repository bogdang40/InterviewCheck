import WorkspaceShell from "@/components/WorkspaceShell"
import type { Metadata } from "next"
import "@fontsource-variable/dm-sans"
import "@fontsource/ibm-plex-mono/400.css"
import "./globals.css"
import "./shell.css"
import "./overview.css"
import "./forms.css"
import "./responsive.css"

export const metadata: Metadata = {
  title: "InterviewCheck | Workspace",
  description: "Review interview answers against their sources.",
}

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <WorkspaceShell>{children}</WorkspaceShell>
      </body>
    </html>
  )
}
