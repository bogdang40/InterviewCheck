import { useState, type FormEvent } from "react"
import { ArrowRight, BriefcaseBusiness, Plus } from "lucide-react"
import { api, message, type Role } from "@/lib/api"
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
  const [name, setName] = useState("")
  const [description, setDescription] = useState("")
  const [questions, setQuestions] = useState("")
  const [generating, setGenerating] = useState(false)
  const [editing, setEditing] = useState(false)
  const [adding, setAdding] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  const [id, setId] = useState(() => crypto.randomUUID())
  function open(role?: Role) {
    setAdding(true)
    setEditing(!!role)
    setError("")
    setId(role?.id ?? crypto.randomUUID())
    setName(role?.name ?? "")
    setDescription(role?.description ?? "")
    setQuestions(role?.questions.join("\n") ?? "")
  }
  async function save(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    if (generating || busy) return
    const form = new FormData(e.currentTarget)
    setBusy(true)
    setError("")
    try {
      const role = await api<Role>(editing ? "roles/" + id : "roles", editing ? "PUT" : "POST", {
        id,
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
        <p>Reuse role descriptions and planned questions across interviews.</p>
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
                onChange={(e) => setName(e.target.value)}
                name="name"
                required
                maxLength={180}
              />
            </label>
            <label className="field">
              Description
              <Textarea
                value={description}
                onChange={(e) => setDescription(e.target.value)}
                name="description"
                maxLength={24000}
              />
            </label>
            <label className="field">
              Planned questions, one per line
              <Textarea value={questions} onChange={(e) => setQuestions(e.target.value)} name="questions" />
            </label>
            <Authoring
              pending={setGenerating}
              task={{
                mode: "questions",
                inputs: () => ({ role: name, description }),
                append: (q) => setQuestions((old) => [old, ...q].filter(Boolean).join("\n")),
              }}
            />
            {error && (
              <p className="error" role="alert">
                {error}
              </p>
            )}
            <div>
              <Button disabled={busy || generating}>Save role</Button>
            </div>
          </form>
        )}
        {roles.map((r) => (
          <div className="role-row" key={r.id}>
            <BriefcaseBusiness />
            <div>
              <strong>{r.name}</strong>
              <p>{r.description || `${r.questions.length} planned questions`}</p>
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
