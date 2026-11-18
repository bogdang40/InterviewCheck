"use client"

import { useRouter } from "next/navigation"
import Dashboard from "./Dashboard"
import WorkspaceError from "./WorkspaceError"
import { usePreparation, useResource, interviewURL } from "@/lib/workspace"
import type { Session } from "@/lib/api"

export default function InterviewList({ archive = false }: { archive?: boolean }) {
  const router = useRouter()
  const list = useResource<Session[]>("sessions")
  const { prepare } = usePreparation()
  if (list.error) return <WorkspaceError text={list.error} retry={list.reload}/>
  return (
    <>
      <Dashboard
        archive={archive}
        sessions={list.data || []}
        loaded={!!list.data}
        onCreate={() => prepare()}
        onOpen={(id) => router.push(interviewURL(id))}
        onSample={() => router.push("/sample/")}
      />
    </>
  )
}
