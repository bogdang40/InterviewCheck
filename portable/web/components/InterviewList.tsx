"use client"

import { useEffect } from "react"
import { useRouter } from "next/navigation"
import Dashboard from "./Dashboard"
import WorkspaceError from "./WorkspaceError"
import { usePreparation, useResource, interviewURL } from "@/lib/workspace"
import type { Overview } from "@/lib/interview-list"
import "@/app/queue.css"
import { PRODUCT_NAME } from "@/lib/brand"

export default function InterviewList() {
  const router = useRouter()
  const list = useResource<Overview>("interviews/overview")
  const { prepare } = usePreparation()
  // "/" carries the public home page's title for link previews; the workspace tab keeps its own.
  useEffect(() => {
    document.title = `${PRODUCT_NAME} | Workspace`
  }, [])
  if (list.error) return <WorkspaceError text={list.error} retry={list.reload}/>
  return <Dashboard overview={list.data} onCreate={() => prepare()} onOpen={id => router.push(interviewURL(id))} onSample={() => router.push("/sample/")}/>
}
