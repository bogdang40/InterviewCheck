import { useLayoutEffect, useRef, useState, type RefObject } from "react"
import { api, message, type Source } from "./api"

export type Pair = { provider: string; style: string }
export type PairResult = Pair & { source?: Source; error?: string }
export const styles = ["Spoken answer", "Talking points", "Worked example"]
export const pairKey = (pair: Pair) => JSON.stringify([pair.provider, pair.style])

export async function generateSources(
  role: string,
  question: string,
  pairs: Pair[],
  count: number,
  signal: AbortSignal,
) {
  if (pairs.length === 1) {
    const source = await api<Source>("authoring/reference", "POST", { role, question, ...pairs[0] }, signal)
    return [{ ...pairs[0], source }] as PairResult[]
  }
  const response = await api<{ results: PairResult[] }>(
    "authoring/references",
    "POST",
    {
      role,
      question,
      pairs,
      existing_reference_count: count,
    },
    signal,
  )
  return response.results
}

export function useAuthoringRun(
  contextId: string,
  version: RefObject<number>,
  pending?: (active: boolean) => void,
) {
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState("")
  const active = useRef<AbortController | null>(null)
  const original = useRef(contextId)
  const discarded = useRef(false)
  const context = JSON.stringify([contextId, version.current])

  useLayoutEffect(() => {
    if (original.current !== context) {
      if (discarded.current) setNotice("The inputs changed. The pending reply was discarded.")
      discarded.current = false
      original.current = context
    }
    return () => {
      if (active.current) {
        active.current.abort()
        active.current = null
        discarded.current = true
        pending?.(false)
        setBusy(false)
      }
    }
  }, [context, pending])

  function cancel() {
    active.current?.abort()
    active.current = null
    setBusy(false)
    pending?.(false)
    setNotice("Pending output discarded. A provider may already have processed the request.")
  }

  async function run<T>(
    request: (signal: AbortSignal) => Promise<T>,
    apply: (data: T) => void,
    failure?: (error: string) => void,
  ) {
    if (active.current) return
    const epoch = version.current
    const controller = new AbortController()
    active.current = controller
    setBusy(true)
    pending?.(true)
    setNotice("")
    try {
      const result = await request(controller.signal)
      if (!controller.signal.aborted) {
        if (version.current === epoch) apply(result)
        else setNotice("The inputs changed. The pending reply was discarded.")
      }
    } catch (error) {
      if (!controller.signal.aborted && version.current === epoch) {
        if (failure) failure(message(error))
        else setNotice(message(error))
      }
    } finally {
      if (active.current === controller) {
        active.current = null
        setBusy(false)
        pending?.(false)
      }
    }
  }
  return { busy, notice, run, cancel, context }
}
