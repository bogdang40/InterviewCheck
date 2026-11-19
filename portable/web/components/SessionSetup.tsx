import { useState, type FormEvent } from "react"
import { ArrowRight } from "lucide-react"
import { Button } from "./ui/button"
import { Input } from "./ui/input"
import AudioPreflight from "./AudioPreflight"
import ResourcePolicy from "./ResourcePolicy"
import { api, message, RoleConflict, type Interview, type PermittedMaterial, type Role } from "@/lib/api"
import ReloadRole from "./ReloadRole"

export default function SessionSetup({
  roles,
  candidate,
  role,
  roleId,
  onStart,
  onRoleLoad,
}: {
  roles: Role[]
  candidate: string
  role: string
  roleId?: string
  onStart: (session: Interview) => void
  onRoleLoad: (role: Role) => void
}) {
  const [id] = useState(() => crypto.randomUUID())
  const initialRole = roles.find(item => item.id === roleId)
  const [policy, setPolicy] = useState(initialRole?.policy || "")
  const [materials, setMaterials] = useState<PermittedMaterial[]>(initialRole?.permitted_sources || [])
  const [notice, setNotice] = useState(false)
  const [selected, setSelected] = useState(initialRole)
  const [roleName, setRoleName] = useState(initialRole?.name ?? role)
  const [conflict, setConflict] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  function selectRole(next?: Role) {
    setSelected(next)
    setRoleName(next?.name ?? "")
    setPolicy(next?.policy ?? "")
    setMaterials(next?.permitted_sources ?? [])
    setNotice(false)
    setConflict(false)
    setError("")
  }
  async function start(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    if (busy || conflict) return
    const data = new FormData(e.currentTarget)
    setBusy(true)
    setError("")
    try {
      onStart(
        await api<Interview>("sessions", "POST", {
          id,
          candidate: data.get("candidate"),
          role: roleName,
          role_id: selected?.id ?? null,
          role_version: selected?.version,
          policy, permitted_sources: materials,
          consent: data.has("consent"),
        }),
      )
    } catch (e) {
      if (e instanceof RoleConflict) {
        setConflict(true)
        setNotice(false)
      }
      setError(message(e))
    } finally {
      setBusy(false)
    }
  }
  return (
    <>
      <div className="page-title">
        <div className="eyebrow">INTERVIEW SETUP</div>
        <h1>New interview</h1>
        <p>Record the rules agreed with the candidate before collecting an answer.</p>
      </div>
      <form className="panel form-panel stack" onSubmit={start}>
        {roles.length > 0 && (
          <label className="field">
            Saved role template
            <select
              value={selected?.id ?? ""}
              disabled={busy}
              onChange={(e) => selectRole(roles.find(r => r.id === e.target.value))}
            >
              <option value="">Enter a role manually</option>
              {roles.map((r) => (
                <option key={r.id} value={r.id}>
                  {r.name}
                  {roles.some((other) => other.id !== r.id && other.name === r.name)
                    ? " · " + (r.description.slice(0, 55) || "Template") + " · " + r.id.slice(0, 8)
                    : ""}
                </option>
              ))}
            </select>
          </label>
        )}
        <div className="dual">
          <label className="field">
            Candidate
            <Input
              required
              name="candidate"
              defaultValue={candidate}
              onChange={() => setNotice(false)}
              maxLength={180}
              placeholder="Name or alias"
            />
          </label>
          <label className="field">
            Role
            <Input
              required
              name="role"
              value={roleName}
              readOnly={!!selected}
              onChange={(e) => { setRoleName(e.target.value); setNotice(false) }}
              maxLength={180}
              placeholder="Role title"
            />
          </label>
        </div>
        {!!selected?.questions.length && <details>
          <summary>Planned questions ({selected.questions.length})</summary>
          <ol>{selected.questions.map((q, i) => <li key={i}>{q}</li>)}</ol>
        </details>}
        <ResourcePolicy policy={policy} required materials={materials}
          onPolicy={value => { setPolicy(value); setNotice(false) }}
          onMaterials={items => { setMaterials(items); setNotice(false) }}/>
        <label className="check">
          <input type="checkbox" name="consent" required checked={notice} onChange={e => setNotice(e.target.checked)} />I confirmed that the candidate knows how their
          answers will be captured and reviewed.
        </label>
        {error && (
          <p role="alert" className="error">
            {error}
          </p>
        )}
        <div>
          {conflict && selected && <ReloadRole id={selected.id} label="Replace setup with saved role"
            onLoad={next => { onRoleLoad(next); selectRole(next) }} />}
          <Button disabled={busy || conflict}>
            {busy ? "Starting…" : "Start interview"}
            <ArrowRight />
          </Button>
        </div>
      </form>
      <AudioPreflight disabled={busy} />
    </>
  )
}
