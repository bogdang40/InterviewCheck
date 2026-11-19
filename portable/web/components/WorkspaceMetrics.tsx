import Link from "next/link"
import { ArrowUpRight, AudioLines, Files, ScanText } from "lucide-react"
import type { Overview } from "@/lib/interview-list"
import { Card } from "./ui/card"

const metrics = [
  { key: "total", label: "Total interviews", icon: Files, href: "/interviews/" },
  { key: "active_count", label: "In progress", icon: AudioLines, href: "/interviews/?status=active" },
  { key: "pending_count", label: "Pending matches", icon: ScanText, href: "/interviews/?review=pending&sort=pending" },
] as const

export default function WorkspaceMetrics({ overview }: { overview: Overview }) {
  return <nav className="workspace-metrics" aria-label="Interview counts">
    {metrics.map(({ key, label, icon: Icon, href }) => (
      <Card asChild key={key} className="metric-card">
        <Link href={href}>
          <span className="metric-label"><Icon size={16} />{label}</span>
          <strong>{overview[key].toLocaleString()}</strong>
          <ArrowUpRight className="metric-arrow" size={16} aria-hidden="true" />
        </Link>
      </Card>
    ))}
  </nav>
}
