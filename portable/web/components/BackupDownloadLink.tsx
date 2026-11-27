import { useCallback, useLayoutEffect, useRef, useState } from "react"
import { Download } from "lucide-react"
import { message } from "@/lib/api"
import { backupURL, downloadBackup } from "@/lib/backupDownload"
import { Button } from "./ui/button"
import { Input } from "./ui/input"

type Result = { state: "idle" | "loading" | "canceled" } | { state: "started"; checksum: string; deferredQuestions?: number } | { state: "error"; detail: string }

export default function BackupDownloadLink({ sessionId }: { sessionId: string | null }) {
  const [result, setResult] = useState<Result>({ state: "idle" })
  const active = useRef<AbortController | null>(null)
  const link = useRef<HTMLAnchorElement>(null)
  const scope = sessionId ? "this interview" : "the entire workspace"

  const cancel = useCallback(() => {
    const controller = active.current
    if (!controller) return
    active.current = null
    controller.abort()
    setResult({ state: "canceled" })
  }, [])

  // The picker keys this component by scope. A cached document can also leave without unmounting.
  useLayoutEffect(() => {
    window.addEventListener("pagehide", cancel)
    return () => {
      window.removeEventListener("pagehide", cancel)
      active.current?.abort()
    }
  }, [cancel])

  async function start() {
    if (active.current) return
    const controller = new AbortController()
    active.current = controller
    setResult({ state: "loading" })
    try {
      const receipt = await downloadBackup(sessionId, controller.signal)
      if (!controller.signal.aborted) setResult({ state: "started", ...receipt })
    } catch (error) {
      if (!controller.signal.aborted) setResult({ state: "error", detail: message(error) })
    } finally {
      if (active.current === controller) active.current = null
    }
  }

  return <>
    <Button asChild className="h-auto max-w-full whitespace-normal">
      <a ref={link} href={backupURL(sessionId)} download aria-disabled={result.state === "loading"} onClick={event => {
        event.preventDefault()
        void start()
      }}>
        <Download aria-hidden="true" />
        {result.state === "error" ? "Retry backup download" : "Download backup"} for {scope}
      </a>
    </Button>
    {result.state === "error" && <p className="error" role="alert">{result.detail}</p>}
    {result.state === "loading" && <>
      <p role="status">Preparing the backup for {scope}…</p>
      <Button type="button" variant="outline" size="sm" onClick={() => {
        cancel()
        link.current?.focus()
      }}>Cancel download</Button>
    </>}
    {result.state === "canceled" && <p role="status">Backup download canceled.</p>}
    {result.state === "started" && <>
      <p role="status">Download started for {scope}.</p>
      {result.deferredQuestions !== undefined && <p>{result.deferredQuestions} deferred {result.deferredQuestions === 1 ? "question" : "questions"} in this backup.</p>}
      <details>
        <summary>Backup checksum</summary>
        <label className="field">
          Downloaded backup SHA-256
          <Input readOnly value={result.checksum} onFocus={event => event.currentTarget.select()} />
        </label>
        <p className="muted">Keep this value separately to check the file during restore.</p>
      </details>
    </>}
  </>
}
