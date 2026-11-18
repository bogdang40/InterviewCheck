import { useState, type FormEvent } from "react"
import { ArrowRight } from "lucide-react"
import { Button } from "./ui/button"
import { Input } from "./ui/input"
import { Textarea } from "./ui/textarea"
import { api, message, type Interview, type Role } from "@/lib/api"

export default function SessionSetup({
  roles,
  candidate,
  role,
  roleId,
  onStart,
}: {
  roles: Role[]
  candidate: string
  role: string
  roleId?: string
  onStart: (session: Interview) => void
}) {
  const [id] = useState(() => crypto.randomUUID())
  const [selectedId, setSelectedId] = useState(roleId ?? "")
  const [roleName, setRoleName] = useState(role)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  async function start(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    const data = new FormData(e.currentTarget)
    setBusy(true)
    setError("")
    try {
      onStart(
        await api<Interview>("sessions", "POST", {
          id,
          candidate: data.get("candidate"),
          role: roleName,
          role_id: selectedId || null,
          policy: data.get("policy"),
          consent: data.has("consent"),
        }),
      )
    } catch (e) {
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
              value={selectedId}
              onChange={(e) => {
                const selected = roles.find((r) => r.id === e.target.value)
                setSelectedId(selected?.id ?? "")
                setRoleName(selected?.name ?? "")
              }}
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
              readOnly={!!selectedId}
              onChange={(e) => setRoleName(e.target.value)}
              maxLength={180}
              placeholder="Role title"
            />
          </label>
        </div>
        <label className="field">
          Assistance policy
          <Textarea
            required
            name="policy"
            maxLength={4000}
            placeholder="Which tools, notes or references may the candidate use?"
          />
        </label>
        <label className="check">
          <input type="checkbox" name="consent" required />I confirmed that the candidate knows how their
          answers will be captured and reviewed.
        </label>
        {error && (
          <p role="alert" className="error">
            {error}
          </p>
        )}
        <div>
          <Button disabled={busy}>
            {busy ? "Starting…" : "Start interview"}
            <ArrowRight />
          </Button>
        </div>
      </form>
    </>
  )
}
