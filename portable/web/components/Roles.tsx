import { useRef, useState, type FormEvent } from "react"
import { ArrowRight, BriefcaseBusiness, History, Plus } from "lucide-react"
import { api, message, RoleConflict, type PermittedMaterial } from "@/lib/api"
import type { CalibratedRole, RubricCriterion } from "@/lib/roleCalibration"
import ReloadRole from "./ReloadRole"
import ResourcePolicy from "./ResourcePolicy"
import Authoring from "./Authoring"
import RoleRubricEditor, { sanitizeRubric } from "./RoleRubricEditor"
import RoleVersionHistory from "./RoleVersionHistory"
import RoleAnalyticsPanel from "./RoleAnalyticsPanel"
import { Button } from "./ui/button"
import { Input } from "./ui/input"
import { Textarea } from "./ui/textarea"

export default function Roles({
  roles,
  onSave,
  prepare,
  onReloadAll,
}: {
  roles: CalibratedRole[]
  onSave: (r: CalibratedRole) => void
  prepare: (role: CalibratedRole) => void
  onReloadAll?: () => void
}) {
  const authoringVersion = useRef(0)
  const [name, setName] = useState("")
  const [description, setDescription] = useState("")
  const [policy, setPolicy] = useState("")
  const [materials, setMaterials] = useState<PermittedMaterial[]>([])
  const [questions, setQuestions] = useState("")
  const [rubric, setRubric] = useState<RubricCriterion[]>([])
  const [changeNote, setChangeNote] = useState("")
  const [generating, setGenerating] = useState(false)
  const [version, setVersion] = useState<string>()
  const [conflict, setConflict] = useState(false)
  const [adding, setAdding] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  const [id, setId] = useState(() => crypto.randomUUID())
  const [historyRoleId, setHistoryRoleId] = useState<string | null>(null)
  const [analyticsRefreshKey, setAnalyticsRefreshKey] = useState(0)
  const [status, setStatus] = useState("")

  const historyRole = roles.find((r) => r.id === historyRoleId) ?? null

  function open(role?: CalibratedRole, preserveStatus = false) {
    authoringVersion.current += 1
    setAdding(true)
    setVersion(role?.version)
    setConflict(false)
    setError("")
    if (!preserveStatus) setStatus("")
    setId(role?.id ?? crypto.randomUUID())
    setName(role?.name ?? "")
    setDescription(role?.description ?? "")
    setPolicy(role?.policy ?? "")
    setMaterials(role?.permitted_sources ?? [])
    setQuestions(role?.questions.join("\n") ?? "")
    setRubric(role?.rubric ?? [])
    setChangeNote("")
  }

  async function save(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    if (generating || busy || conflict) return
    const form = new FormData(e.currentTarget)
    const isEdit = Boolean(version)
    setBusy(true)
    setError("")
    try {
      const role = await api<CalibratedRole>(version ? "roles/" + id : "roles", version ? "PUT" : "POST", {
        id,
        version,
        policy,
        permitted_sources: materials,
        name: form.get("name"),
        description: form.get("description"),
        questions: String(form.get("questions"))
          .split("\n")
          .map((s) => s.trim())
          .filter(Boolean),
        rubric: sanitizeRubric(rubric),
        change_note: changeNote.trim(),
      })
      onSave(role)
      setAnalyticsRefreshKey((k) => k + 1)
      setStatus(`${isEdit ? "Saved" : "Created"} role ${role.name} (v${role.version_number ?? 1}).`)
      setAdding(false)
      setName("")
      setDescription("")
      setQuestions("")
      setRubric([])
      setChangeNote("")
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
        <p>Prepare interview questions, rubric criteria, assistance policies and permitted sources for each role.</p>
      </div>
      <section className="panel">
        <div className="panel-head">
          <h2>Saved roles</h2>
          <Button
            size="sm"
            className="min-h-[44px] md:min-h-8"
            disabled={busy || generating}
            onClick={() => (adding ? setAdding(false) : open())}
            variant={adding ? "outline" : "default"}
          >
            {!adding && <Plus aria-hidden="true" />}
            {adding ? "Cancel" : "Add role"}
          </Button>
        </div>
        {status && (
          <p
            role="status"
            aria-live="polite"
            className="mx-[22px] mb-3 rounded-md border border-[var(--success-line)] bg-[var(--success-bg)] px-3 py-2 text-sm text-[var(--success-text)]"
          >
            {status}
          </p>
        )}
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
            <RoleRubricEditor
              rubric={rubric}
              changeNote={changeNote}
              disabled={busy || generating || conflict}
              onRubric={setRubric}
              onChangeNote={setChangeNote}
            />
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
                <ReloadRole
                  id={id}
                  label="Discard edits and load saved role"
                  onLoad={role => {
                    onSave(role)
                    open(role, true)
                    setStatus(`Reloaded saved role ${role.name}.`)
                  }}
                />
                <Button type="button" variant="outline" className="min-h-[44px] md:min-h-9" onClick={() => {
                  setId(crypto.randomUUID())
                  setVersion(undefined)
                  setConflict(false)
                  setError("")
                }}>Keep edits as a new role</Button>
              </div> : <Button className="min-h-[44px] md:min-h-9" disabled={busy || generating}>Save role</Button>}
            </div>
          </form>
        )}
        {roles.map((r) => (
          <div className="role-row" key={r.id}>
            <BriefcaseBusiness aria-hidden="true" />
            <div>
              <strong>{r.name}</strong>
              <p>{r.description || `${r.questions.length} planned questions`}</p>
              <small>
                v{r.version_number ?? 1}
                {!!r.rubric?.length && ` | ${r.rubric.length} rubric ${r.rubric.length === 1 ? "criterion" : "criteria"}`}
                {!!r.permitted_sources?.length && ` | ${r.permitted_sources.length} permitted ${r.permitted_sources.length === 1 ? "source" : "sources"}`}
              </small>
            </div>
            <span className="ml-auto flex flex-wrap items-center gap-2 max-sm:w-full">
              <Button
                type="button"
                variant={historyRoleId === r.id ? "secondary" : "outline"}
                size="sm"
                className="min-h-[44px] md:min-h-8"
                aria-label={`Version history for ${r.name}`}
                onClick={() => setHistoryRoleId((cur) => (cur === r.id ? null : r.id))}
              >
                <History aria-hidden="true" />
                Versions
              </Button>
              <Button
                disabled={adding}
                variant="outline"
                size="sm"
                className="min-h-[44px] md:min-h-8"
                aria-label={`Edit role ${r.name}`}
                onClick={() => open(r)}
              >
                Edit role
              </Button>
              <Button
                variant="ghost"
                className="min-h-[44px] md:min-h-9"
                aria-label={`Prepare interview for ${r.name}`}
                onClick={() => prepare(r)}
              >
                Prepare <ArrowRight aria-hidden="true" />
              </Button>
            </span>
          </div>
        ))}
        {!roles.length && !adding && (
          <div className="empty">
            <BriefcaseBusiness aria-hidden="true" />
            <strong>No roles saved</strong>
            <p>Add a role or migrate role profiles from a native database.</p>
            <Button variant="outline" size="sm" className="min-h-[44px] md:min-h-8" onClick={() => open()}>
              Create a role
            </Button>
          </div>
        )}
      </section>
      {historyRole && (
        <RoleVersionHistory
          role={historyRole}
          onRestored={(updated) => {
            onSave(updated)
            setAnalyticsRefreshKey((k) => k + 1)
            setStatus(`Restored role ${updated.name} to version ${updated.version_number ?? 1}.`)
          }}
          onConflictReload={() => {
            onReloadAll?.()
            setStatus("Reloaded role library.")
          }}
          onClose={() => setHistoryRoleId(null)}
        />
      )}
      <RoleAnalyticsPanel refreshKey={analyticsRefreshKey} />
    </>
  )
}
