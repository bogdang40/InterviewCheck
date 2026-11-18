"use client"

import Link from "next/link"
import { useEffect, useState } from "react"
import { ArchiveRestore, Trash2 } from "lucide-react"
import { api, dateLabel, message } from "@/lib/api"
import { interviewURL, useResource } from "@/lib/workspace"
import { moveNotice, rememberMove, type TrashedInterview, type TrashPage } from "@/lib/trash"
import WorkspaceError from "./WorkspaceError"
import { Button } from "./ui/button"
import { Input } from "./ui/input"
import styles from "./TrashList.module.css"

export default function TrashList() {
  const [page, setPage] = useState(1)
  const result = useResource<TrashPage>("trash?page=" + page)
  const [recent, setRecent] = useState<ReturnType<typeof moveNotice>>(null)
  const [deleting, setDeleting] = useState<TrashedInterview | null>(null)
  const [typed, setTyped] = useState("")
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  const [notice, setNotice] = useState("")
  const [restored, setRestored] = useState<string | null>(null)
  useEffect(() => setRecent(moveNotice()), [])
  function select(item: TrashedInterview | null) {
    setDeleting(item)
    setTyped("")
    setError("")
    setNotice("")
    setRestored(null)
  }
  async function act(item: TrashedInterview, purge: boolean) {
    if (busy || (purge && (deleting?.id !== item.id || typed.trim().toLowerCase() !== item.id))) return
    setBusy(true)
    setError("")
    setNotice("")
    setRestored(null)
    try {
      const payload = {
        operation_version: item.operation_version,
        ...(purge ? { confirm_session_id: typed.trim() } : {}),
      }
      await api(`trash/${item.id}/${purge ? "purge" : "restore"}`, "POST", payload)
      if (recent?.id === item.id) {
        rememberMove(null)
        setRecent(null)
      }
      setNotice(
        (purge ? "Permanently deleted" : "Restored") +
          " the interview for " +
          (item.candidate || "unnamed candidate") +
          ".",
      )
      if (!purge) setRestored(item.id)
      setDeleting(null)
      setTyped("")
      result.reload()
    } catch (e) {
      setError(message(e))
      setDeleting(null)
      setTyped("")
      result.reload()
    } finally {
      setBusy(false)
    }
  }
  const data = result.data
  return (
    <div className="stack">
      <header className="page-title">
        <h1>Trash</h1>
        <p>Restore an interview or permanently delete its local records.</p>
      </header>
      {error && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
      {notice && (
        <p role="status" className="notice">
          {notice} {restored && <Link href={interviewURL(restored)}>Open restored interview</Link>}
        </p>
      )}
      {result.error ? (
        <WorkspaceError text={result.error} retry={result.reload} />
      ) : !data ? (
        <p role="status">Loading Trash…</p>
      ) : !data.items.length ? (
        <section className="panel form-panel">
          <h2>Trash is empty</h2>
          <Link href="/interviews/">View interviews</Link>
        </section>
      ) : (
        <>
          <section className="panel form-panel">
            <h2>
              {data.total} {data.total === 1 ? "interview" : "interviews"} in Trash
            </h2>
            <ul className={styles.list}>
              {data.items.map((item) => {
                const moved = recent?.id === item.id && recent.operation_version === item.operation_version
                return (
                  <li className={styles.item} key={item.id}>
                    <div className="spread">
                      <div className={styles.identity}>
                        <strong>{item.candidate || "Unnamed candidate"}</strong>
                        <p>{item.role}</p>
                        <p className={styles.meta}>
                          {dateLabel(item.created_at)} · {item.answer_count}{" "}
                          {item.answer_count === 1 ? "exchange" : "exchanges"} · Moved{" "}
                          {dateLabel(item.trashed_at)}
                        </p>
                        <code className={styles.meta}>{item.id}</code>
                      </div>
                      <div className="row">
                        <Button
                          variant="outline"
                          size="sm"
                          disabled={busy || !!deleting}
                          onClick={() => act(item, false)}
                        >
                          <ArchiveRestore />
                          {moved ? "Undo move" : "Restore interview"}
                        </Button>
                        <Button
                          variant="ghost"
                          size="sm"
                          disabled={busy || !!deleting}
                          onClick={() => select(item)}
                        >
                          <Trash2 />
                          Delete permanently
                        </Button>
                      </div>
                    </div>
                    {deleting?.id === item.id && (
                      <form
                        className={`notice stack ${styles.confirm}`}
                        onSubmit={(e) => {
                          e.preventDefault()
                          void act(deleting, true)
                        }}
                      >
                        <strong>
                          Permanently delete the interview for {deleting.candidate || "unnamed candidate"}?
                        </strong>
                        <p>
                          This removes its exchanges, notes, saved draft and local delivery history. To
                          confirm, enter <code>{deleting.id}</code>.
                        </p>
                        <label className="field">
                          Interview ID to confirm
                          <Input
                            autoFocus
                            autoComplete="off"
                            spellCheck={false}
                            value={typed}
                            disabled={busy}
                            onChange={(e) => setTyped(e.target.value)}
                          />
                        </label>
                        <div className="row">
                          <Button
                            variant="destructive"
                            disabled={busy || typed.trim().toLowerCase() !== deleting.id}
                          >
                            Confirm permanent deletion
                          </Button>
                          <Button type="button" variant="ghost" disabled={busy} onClick={() => select(null)}>
                            Cancel deletion
                          </Button>
                        </div>
                      </form>
                    )}
                  </li>
                )
              })}
            </ul>
          </section>
          {data.total > data.page_size && (
            <div className="row">
              <Button
                variant="outline"
                disabled={busy || !!deleting || data.page <= 1}
                onClick={() => setPage(data.page - 1)}
              >
                Previous page
              </Button>
              <span>
                Page {data.page} of {Math.ceil(data.total / data.page_size)}
              </span>
              <Button
                variant="outline"
                disabled={busy || !!deleting || data.page * data.page_size >= data.total}
                onClick={() => setPage(data.page + 1)}
              >
                Next page
              </Button>
            </div>
          )}
        </>
      )}
    </div>
  )
}
