"use client"

import { Suspense } from "react"
import { useRouter } from "next/navigation"
import Dashboard from "./Dashboard"
import InterviewArchive from "./InterviewArchive"
import WorkspaceError from "./WorkspaceError"
import { usePreparation, useResource, interviewURL } from "@/lib/workspace"
import type { Overview } from "@/lib/interview-list"
import "@/app/queue.css"

export default function InterviewList({ archive = false }: { archive?: boolean }) {
  const router = useRouter()
  const list = useResource<Overview>(archive ? null : "interviews/overview")
  const { prepare } = usePreparation()
  if (list.error) return <WorkspaceError text={list.error} retry={list.reload}/>
  if (archive) return <Suspense fallback={<h1>Interviews</h1>}><InterviewArchive onCreate={() => prepare()}/></Suspense>
  return <Dashboard overview={list.data} onCreate={() => prepare()} onOpen={id => router.push(interviewURL(id))} onSample={() => router.push("/sample/")}/>
}
