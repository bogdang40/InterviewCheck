import { useRef, useState, type FormEvent } from "react"
import dynamic from "next/dynamic"
import { ArrowRight, BriefcaseBusiness, Copy, History, Plus } from "lucide-react"
import { api, message, RoleConflict, type PermittedMaterial } from "@/lib/api"
import type { CalibratedRole, RubricCriterion } from "@/lib/roleCalibration"
import { revisionNumber } from "@/lib/revisionNumber"
import { cloneRole } from "@/lib/roleTemplates"
import { useDraftGuard } from "@/lib/useDraftGuard"
import ReloadRole from "./ReloadRole"
import ResourcePolicy from "./ResourcePolicy"
import RoleFileActions from "./RoleFileActions"
import Authoring from "./Authoring"
import RoleRubricEditor, { sanitizeRubric } from "./RoleRubricEditor"
import RoleAnalyticsPanel from "./RoleAnalyticsPanel"
import { Button } from "./ui/button"
import { Input } from "./ui/input"
import { Textarea } from "./ui/textarea"

const RoleVersionHistory = dynamic(() => import("./RoleVersionHistory"), {
  ssr: false,
  loading: () => <p className="muted" role="status">Loading role history...</p>,
})

type RoleFormFields = [string, string, string, PermittedMaterial[], string, RubricCriterion[], string]
const roleFormSnapshot = (fields: RoleFormFields) => JSON.stringify(fields)

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
  const savedQuestions = useRef<string[]>([])
  const openedSnapshot = useRef("")
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
  const [cloningId, setCloningId] = useState<string | null>(null)
  const [cloneError, setCloneError] = useState("")

  const historyRole = roles.find((r) => r.id === historyRoleId) ?? null
  const formDirty = adding &&
    roleFormSnapshot([name, description, policy, materials, questions, rubric, changeNote]) !== openedSnapshot.current
  useDraftGuard(formDirty, "Discard unsaved role changes and leave this page?")

  async function handleClone(role: CalibratedRole) {
    if (cloningId || busy || generating) return
    setCloningId(role.id)
    setCloneError("")
    setStatus("")
    try {
      const cloned = await cloneRole(role.id)
      onSave(cloned)
      setAnalyticsRefreshKey((k) => k + 1)
      setStatus(`Cloned role ${role.name} as ${cloned.name}.`)
    } catch (err) {
      setCloneError(message(err))
    } finally {
      setCloningId(null)
    }
  }

  function open(role?: CalibratedRole, preserveStatus = false) {
    authoringVersion.current += 1
    savedQuestions.current = role?.questions ?? []
    setAdding(true)
    setVersion(role?.version)
    setConflict(false)
    setError("")
    setCloneError("")
    if (!preserveStatus) setStatus("")
    setId(role?.id ?? crypto.randomUUID())
    setName(role?.name ?? "")
    setDescription(role?.description ?? "")
    setPolicy(role?.policy ?? "")
    setMaterials(role?.permitted_sources ?? [])
    setQuestions(role?.questions.join("\n") ?? "")
    setRubric(role?.rubric ?? [])
    setChangeNote("")
    openedSnapshot.current = roleFormSnapshot([
      role?.name ?? "", role?.description ?? "", role?.policy ?? "", role?.permitted_sources ?? [],
      role?.questions.join("\n") ?? "", role?.rubric ?? [], "",
    ])
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
        questions: questions === savedQuestions.current.join("\n")
          ? savedQuestions.current
          : questions.split("\n").map((s) => s.trim()).filter(Boolean),
        rubric: sanitizeRubric(rubric),
        change_note: changeNote.trim(),
      })
      onSave(role)
      setAnalyticsRefreshKey((k) => k + 1)
      setStatus(`${isEdit ? "Saved" : "Created"} role ${role.name} (v${revisionNumber(role.version_number, role.version_number_text) || "unavailable"}).`)
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
        {cloneError && (
          <p role="alert" className="mx-[22px] mb-3 error">
            {cloneError}
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
                v{revisionNumber(r.version_number, r.version_number_text) || "unavailable"}
                {!!r.rubric?.length && ` | ${r.rubric.length} rubric ${r.rubric.length === 1 ? "criterion" : "criteria"}`}
                {!!r.permitted_sources?.length && ` | ${r.permitted_sources.length} permitted ${r.permitted_sources.length === 1 ? "source" : "sources"}`}
              </small>
              <RoleFileActions role={r} disabled={adding} onDuplicate={onSave} onEdit={open} />
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
                type="button"
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
                type="button"
                disabled={adding || cloningId !== null}
                variant="outline"
                size="sm"
                className="min-h-[44px] md:min-h-8"
                aria-label={`Clone role ${r.name}`}
                onClick={() => void handleClone(r)}
              >
                <Copy aria-hidden="true" />
                {cloningId === r.id ? "Cloning..." : "Clone"}
              </Button>
              <Button
                type="button"
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
          key={historyRole.id}
          role={historyRole}
          onRestored={(updated) => {
            onSave(updated)
            setAnalyticsRefreshKey((k) => k + 1)
            setStatus(`Restored role ${updated.name} to version ${revisionNumber(updated.version_number, updated.version_number_text) || "unavailable"}.`)
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
