"use client"

import { Suspense } from "react"
import dynamic from "next/dynamic"
import Link from "next/link"
import { useSearchParams } from "next/navigation"
import { Button } from "@/components/ui/button"
import InterviewView from "@/components/InterviewView"
import WorkspaceError from "@/components/WorkspaceError"
import type { Answer, Interview } from "@/lib/api"
import { useResource } from "@/lib/workspace"

const SessionAssignmentBar = dynamic(() => import("@/components/SessionAssignmentBar"), {
  ssr: false,
  loading: () => (
    <section className="panel inset" role="status">
      <p className="muted">Loading assignment...</p>
    </section>
  ),
})

function Record() {
  const query = useSearchParams()
  const id = query.get("id")
  const valid = id && /^[\da-f-]{36}$/i.test(id)
  const session = useResource<Interview>(valid ? "sessions/" + id : null)
  if (!valid)
    return (
      <section className="panel stack">
        <div className="page-title">
          <span className="eyebrow">INTERVIEW RECORD</span>
          <h1>Interview review</h1>
        </div>
        <p role="alert">
          Choose a session from <Link href="/interviews/">Interviews</Link>.
        </p>
        <div>
          <Button asChild variant="outline" size="sm">
            <Link href="/interviews/">Open interviews</Link>
          </Button>
        </div>
      </section>
    )
  if (session.error) return <WorkspaceError text={session.error} retry={session.reload} />
  if (!session.data) return <section className="panel inset" role="status"><p className="muted">Loading interview…</p></section>
  function change(_: string, item: Answer) {
    session.update((previous) => {
      const answers = previous.answers.some((a) => a.id === item.id)
        ? previous.answers.map((a) => (a.id === item.id ? item : a))
        : [...previous.answers, item]
      return {
        ...previous,
        answers,
        answer_count: answers.length,
        review_count: answers.filter((a) => a.result.status === "match" && a.disposition === "pending")
          .length,
      }
    })
  }
  return (
    <div className="stack">
      <SessionAssignmentBar key={session.data.id} sessionId={session.data.id} />
      <InterviewView
        key={id}
        session={session.data}
        answerId={query.get("answer")}
        changed={change}
        onDraftChange={draft=>session.update(previous=>({...previous,draft}))}
        onTransition={(next) => session.update(() => next)}
      />
    </div>
  )
}
export default function ReviewPage() {
  return (
    <Suspense fallback={<p role="status">Loading interview…</p>}>
      <Record />
    </Suspense>
  )
}
