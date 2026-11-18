"use client"

import { createContext, useContext, useEffect, useState } from "react"
import { api, message } from "./api"

export type Preparation = { candidate: string; role: string; roleId?: string }
export const blankPreparation: Preparation = { candidate: "", role: "" }
export const PreparationContext = createContext({
  preparation: blankPreparation,
  prepare: (_input?: Preparation) => {},
})
export const usePreparation = () => useContext(PreparationContext)
export const interviewURL = (id: string) => "/interviews/review/?id=" + encodeURIComponent(id)

export function useResource<T>(path: string | null) {
  const [resource, setResource] = useState<{ path: string; value: T } | null>(null)
  const [failure, setFailure] = useState<{ path: string; text: string } | null>(null)
  const [revision, setRevision] = useState(0)
  useEffect(() => {
    if (!path) return
    let active = true
    setFailure(null)
    api<T>(path)
      .then((value) => {
        if (active) setResource({ path, value })
      })
      .catch((e) => {
        if (active) setFailure({ path, text: message(e) })
      })
    return () => {
      active = false
    }
  }, [path, revision])
  return {
    data: resource && resource.path === path ? resource.value : null,
    error: failure?.path === path ? failure.text : "",
    reload: () => setRevision((n) => n + 1),
    update: (fn: (previous: T) => T) =>
      setResource((last) => (last && last.path === path ? { ...last, value: fn(last.value) } : last)),
  }
}
