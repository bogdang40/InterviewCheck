import { useCallback, useEffect, useRef, useState } from "react"

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

/** Report an editor's unsaved state to its parent, and clear it when the editor unmounts. */
export function useReportDirty(dirty: boolean, report?: DirtyReporter) {
  useEffect(() => {
    report?.(dirty)
  }, [dirty, report])
  useEffect(() => () => report?.(false), [report])
}
