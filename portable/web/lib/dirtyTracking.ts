import { useCallback, useRef, useState } from "react"
import { useIsomorphicLayoutEffect } from "./useIsomorphicLayoutEffect"

export type DirtyReporter = (dirty: boolean) => void

/**
 * Collects unsaved-edit flags from several child editors so a parent can guard navigation once,
 * instead of every editor installing its own confirm prompt.
 */
export function useDirtyRegistry() {
  const [dirtyKeys, setDirtyKeys] = useState<ReadonlySet<string>>(() => new Set())
  const reporters = useRef(new Map<string, DirtyReporter>())

  const reporterFor = useCallback((key: string): DirtyReporter => {
    let reporter = reporters.current.get(key)
    if (!reporter) {
      reporter = (dirty: boolean) =>
        setDirtyKeys((prev) => {
          if (prev.has(key) === dirty) return prev
          const next = new Set(prev)
          if (dirty) next.add(key)
          else next.delete(key)
          return next
        })
      reporters.current.set(key, reporter)
    }
    return reporter
  }, [])

  return { anyDirty: dirtyKeys.size > 0, reporterFor }
}

/** Keep the navigation guard in sync with the committed editors before the browser can leave. */
export function useReportDirty(dirty: boolean, report?: DirtyReporter) {
  useIsomorphicLayoutEffect(() => {
    report?.(dirty)
  }, [dirty, report])
  useIsomorphicLayoutEffect(() => () => report?.(false), [report])
}

/** Capture permission to change the visible editor before an asynchronous read or write. */
export function useReviewNavigationGuard(locked: boolean, source?: string) {
  const current = useRef<symbol | null>(null)
  useIsomorphicLayoutEffect(() => {
    current.current = locked ? null : Symbol()
    return () => { current.current = null }
  }, [locked, source])
  return () => {
    const started = current.current
    return () => started !== null && current.current === started
  }
}
