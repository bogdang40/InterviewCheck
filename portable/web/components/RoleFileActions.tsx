import { useRef, useState } from "react"
import { api, message, type Role } from "@/lib/api"
import { saveBlob } from "@/lib/download"
import { detailOr, send } from "@/lib/http"
import { Button } from "./ui/button"

export default function RoleFileActions({ id, disabled, onDuplicate, onEdit }: {
  id: string
  disabled: boolean
  onDuplicate: (role: Role) => void
  onEdit: (role: Role) => void
}) {
  const copyId = useRef<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  const [copy, setCopy] = useState<Role>()
  const path = "roles/" + id

  async function perform(action: "duplicate" | "export") {
    if (busy || disabled) return
    setBusy(true)
    setError("")
    try {
      if (action === "duplicate") {
        copyId.current ??= crypto.randomUUID()
        const role = await api<Role>(path + "/duplicate", "POST", { id: copyId.current })
        copyId.current = null
        setCopy(role)
        onDuplicate(role)
      } else {
        const response = await send("/api/" + path + "/export", {
          describe: (data) => detailOr(data, "The role file could not be downloaded."),
        })
        saveBlob(await response.blob(), "role-" + id + ".json")
      }
    } catch (e) {
      setError(message(e))
    } finally {
      setBusy(false)
    }
  }

  return <details className="import">
    <summary>Role file and copy</summary>
    <div className="stack">
      <p>Export the saved questions, grading rubric, description, policy and permitted materials for another portable workspace.</p>
      <div><Button type="button" size="sm" variant="outline" disabled={busy || disabled}
        onClick={() => perform("export")}>Export role file</Button></div>
      <div><Button type="button" size="sm" variant="outline" disabled={busy || disabled}
        onClick={() => perform("duplicate")}>Duplicate latest saved role</Button></div>
      {error && <p role="alert" className="error">{error}</p>}
      {copy && <div><p role="status">Separate copy saved.</p>
        <Button type="button" size="sm" variant="ghost" disabled={disabled || busy}
          onClick={() => onEdit(copy)}>Edit copy</Button></div>}
    </div>
  </details>
}
