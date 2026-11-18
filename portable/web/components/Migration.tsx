"use client"

import { useRef, useState } from "react"
import { ArchiveRestore, FileInput } from "lucide-react"
import { api, message } from "@/lib/api"
import { Button } from "./ui/button"

type Preview = { id: string; name: string; question_count: number; duplicate: boolean }

export function Migration({ onImported }: { onImported?: () => void } ) {
  const [preview, setPreview] = useState<Preview | null>(null)
  const [document, setDocument] = useState<unknown>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  const [status, setStatus] = useState("")
  const readSequence = useRef(0)

  async function inspect(file?: File) {
    const sequence = ++readSequence.current
    setPreview(null)
    setDocument(null)
    setError("")
    setStatus("")
    if (!file) return
    setBusy(true)
    try {
      if (file.size > 2_000_000) throw new Error("Select a role export under 2 MB.")
      const source = JSON.parse(await file.text())
      const checked = await api<Preview>("roles/import/preview", "POST", source)
      if (sequence !== readSequence.current) return
      setDocument(source)
      setPreview(checked)
    } catch (error) {
      if (sequence === readSequence.current) setError(message(error))
    } finally {
      if (sequence === readSequence.current) setBusy(false)
    }
  }

  async function importRole() {
    if (!preview || preview.duplicate || !document) return
    setBusy(true)
    setError("")
    try {
      await api("roles/import", "POST", document)
      setStatus("Role available in the library.")
      setPreview(null)
      setDocument(null)
      onImported?.()
    } catch (error) {
      setError(message(error))
    } finally {
      setBusy(false)
    }
  }

  return <section className="panel stack">
    <h2><ArchiveRestore size={18}/> Native migration</h2>
    <details className="import"><summary>Import a role file</summary>
      <div className="stack">
        <label className="field">Native role export
          <input type="file" accept=".json,application/json" disabled={busy}
            onChange={event => { void inspect(event.target.files?.[0]); event.target.value = "" }}/>
        </label>
        {preview && <div className="notice"><strong>{preview.name}</strong>
          <p>{preview.question_count} planned {preview.question_count === 1 ? "question" : "questions"}.</p>
          {preview.duplicate ? <p role="status">This role is already in the library.</p> :
            <Button type="button" size="sm" disabled={busy} onClick={importRole}><FileInput/>Import role</Button>}
        </div>}
        {error && <p className="error" role="alert">{error}</p>}
        {status && <p role="status">{status}</p>}
      </div>
    </details>
    <details className="import"><summary>Move native interviews and reports</summary>
      <div className="stack">
        <p>Make a SQLite backup of the native database. Copy the backup to this computer.
          Run the import from the portable directory against the same workspace database as the service.</p>
        <div><strong>Windows PowerShell</strong>
          <pre style={{whiteSpace: "pre-wrap"}}>{'.\\.venv\\Scripts\\python.exe -m api.migrate "C:\\path\\interview-snapshot.sqlite"'}</pre>
        </div>
        <div><strong>Linux</strong>
          <pre style={{whiteSpace: "pre-wrap"}}>{'.venv/bin/python -m api.migrate "/path/interview-snapshot.sqlite"'}</pre>
        </div>
        <p>Open the interview archive after import. Each report retains its native scores, notes and references.
          Repeating an import skips records already present.</p>
      </div>
    </details>
  </section>
}

export default Migration
