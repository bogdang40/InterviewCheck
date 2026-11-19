import { useRef, useState, type FormEvent } from "react"
import { ArrowRight, BriefcaseBusiness, Plus } from "lucide-react"
import { api, message, RoleConflict, type PermittedMaterial, type Role } from "@/lib/api"
import ReloadRole from "./ReloadRole"
import ResourcePolicy from "./ResourcePolicy"
import Authoring from "./Authoring"
import { Button } from "./ui/button"
import { Input } from "./ui/input"
import { Textarea } from "./ui/textarea"

export default function Roles({
  roles,
  onSave,
  prepare,
}: {
  roles: Role[]
  onSave: (r: Role) => void
  prepare: (role: Role) => void
}) {
  const authoringVersion = useRef(0)
  const [name, setName] = useState("")
  const [description, setDescription] = useState("")
  const [policy, setPolicy] = useState("")
  const [materials, setMaterials] = useState<PermittedMaterial[]>([])
  const [questions, setQuestions] = useState("")
  const [generating, setGenerating] = useState(false)
  const [version, setVersion] = useState<string>()
  const [conflict, setConflict] = useState(false)
  const [adding, setAdding] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  const [id, setId] = useState(() => crypto.randomUUID())
  function open(role?: Role) {
    authoringVersion.current += 1
    setAdding(true)
    setVersion(role?.version)
    setConflict(false)
    setError("")
    setId(role?.id ?? crypto.randomUUID())
    setName(role?.name ?? "")
    setDescription(role?.description ?? "")
    setPolicy(role?.policy ?? "")
    setMaterials(role?.permitted_sources ?? [])
    setQuestions(role?.questions.join("\n") ?? "")
  }
  async function save(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    if (generating || busy || conflict) return
    const form = new FormData(e.currentTarget)
    setBusy(true)
    setError("")
    try {
      const role = await api<Role>(version ? "roles/" + id : "roles", version ? "PUT" : "POST", {
        id, version, policy, permitted_sources: materials,
        name: form.get("name"),
        description: form.get("description"),
        questions: String(form.get("questions"))
          .split("\n")
          .map((s) => s.trim())
          .filter(Boolean),
      })
      onSave(role)
      setAdding(false)
      setName("")
      setDescription("")
      setQuestions("")
      setId(crypto.randomUUID())
    } catch (e) {
      setConflict(e instanceof RoleConflict)
      setError(message(e))
    } finally {
      setBusy(false)
    }
  }
  return (
    <>
      <div className="page-title">
        <span className="eyebrow">LIBRARY</span>
        <h1>Role library</h1>
        <p>Prepare interview questions, assistance policies and permitted sources for each role.</p>
      </div>
      <section className="panel">
        <div className="panel-head">
          <h2>Saved roles</h2>
          <Button
            size="sm"
            disabled={busy || generating}
            onClick={() => (adding ? setAdding(false) : open())}
            variant={adding ? "outline" : "default"}
          >
            {!adding && <Plus />}
            {adding ? "Cancel" : "Add role"}
          </Button>
        </div>
        {adding && (
          <form className="stack inset" onSubmit={save}>
            <label className="field">
              Role name
              <Input
                value={name}
                onChange={e => { authoringVersion.current += 1; setName(e.target.value) }}
                name="name"
                required
                maxLength={180}
              />
            </label>
            <label className="field">
              Description
              <Textarea
                value={description}
                onChange={e => { authoringVersion.current += 1; setDescription(e.target.value) }}
                name="description"
                maxLength={24000}
              />
            </label>
            <label className="field">
              Planned questions, one per line
              <Textarea value={questions} onChange={(e) => setQuestions(e.target.value)} name="questions" />
            </label>
            <ResourcePolicy policy={policy} onPolicy={setPolicy} materials={materials} onMaterials={setMaterials}/>
            <Authoring
              pending={setGenerating}
              disabled={busy || conflict || questions.split("\n").filter(line => line.trim()).length >= 100}
              task={{
                mode: "questions",
                id, role: name, description, version: authoringVersion,
                append: generated => setQuestions(old => {
                  const existing = old.split("\n").map(line => line.trim()).filter(Boolean)
                  const added = generated.filter(question => !existing.includes(question)).slice(0, Math.max(0, 100 - existing.length))
                  return [old, ...added].filter(Boolean).join("\n")
                }),
              }}
            />
            {error && (
              <p className="error" role="alert">
                {error}
              </p>
            )}
            <div>
              {conflict ? <div className="stack">
                <ReloadRole id={id} label="Discard edits and load saved role" onLoad={role => { onSave(role); open(role) }} />
                <Button type="button" variant="outline" onClick={() => {
                  setId(crypto.randomUUID())
                  setVersion(undefined)
                  setConflict(false)
                  setError("")
                }}>Keep edits as a new role</Button>
              </div> : <Button disabled={busy || generating}>Save role</Button>}
            </div>
          </form>
        )}
        {roles.map((r) => (
          <div className="role-row" key={r.id}>
            <BriefcaseBusiness />
            <div>
              <strong>{r.name}</strong>
              <p>{r.description || `${r.questions.length} planned questions`}</p>
              {!!r.permitted_sources?.length && <small>{r.permitted_sources.length} permitted {r.permitted_sources.length === 1 ? "source" : "sources"}</small>}
            </div>
            <Button disabled={adding} variant="outline" size="sm" onClick={() => open(r)}>
              Edit role
            </Button>
            <Button variant="ghost" onClick={() => prepare(r)}>
              Prepare <ArrowRight />
            </Button>
          </div>
        ))}
        {!roles.length && !adding && (
          <div className="empty">
            <BriefcaseBusiness />
            <strong>No roles saved</strong>
            <p>Add a role or migrate role profiles from a native database.</p>
          </div>
        )}
      </section>
    </>
  )
}
