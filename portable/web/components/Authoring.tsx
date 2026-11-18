import { useEffect, useState, type RefObject } from "react"
import { WandSparkles } from "lucide-react"
import { Button } from "./ui/button"
import { api, message, type Source } from "@/lib/api"
import { useAuthoringRun } from "@/lib/authoring"
import ReferenceLineup from "./ReferenceLineup"
import "./Authoring.css"

type Shared = { id: string; role: string; version: RefObject<number> }
type Task = Shared & (
  | { mode: "questions"; description: string; append: (questions: string[]) => void }
  | { mode: "reference"; question: string; count: number; append: (sources: Source[]) => void }
)

export default function Authoring({ task, disabled = false, pending }: {
  task: Task; disabled?: boolean; pending?: (active: boolean) => void
}) {
  const [providers, setProviders] = useState<string[]>([])
  const [provider, setProvider] = useState("")
  const [error, setError] = useState("")
  const role = task.role.trim()
  const text = (task.mode === "questions" ? task.description : task.question).trim()
  const state = useAuthoringRun(JSON.stringify([task.id, task.mode, role, text]), task.version, pending)
  useEffect(() => {
    const controller = new AbortController()
    api<string[]>("authoring/providers", "GET", undefined, controller.signal)
      .then(list => { if (!controller.signal.aborted) { setProviders(list); setProvider(list[0] ?? "") } })
      .catch(e => { if (!controller.signal.aborted) setError(message(e)) })
    return () => controller.abort()
  }, [])
  if (!providers.length && !error) return null
  return <details className="import authoring-panel">
    <summary>{task.mode === "questions" ? "Draft role questions" : "Generate a reference answer"}</summary>
    {error && <p role="alert" className="error">{error}</p>}
    {!!providers.length && <div className="stack">
      <div className="outgoing-fields"><strong>Content sent</strong>
        <dl><dt>Role</dt><dd>{role || "Enter the role."}</dd>
          <dt>{task.mode === "questions" ? "Job description" : "Interview question"}</dt>
          <dd>{text || (task.mode === "questions" ? "Enter the job description." : "Enter the question.")}</dd></dl>
      </div>
      {task.mode === "reference" ? <ReferenceLineup key={task.id}
        providers={providers} role={role} question={text} count={task.count} append={task.append}
        disabled={disabled} runState={state}/> : <>
        <label className="field">Provider<select disabled={state.busy} value={provider} onChange={e => setProvider(e.target.value)}>
          {providers.map(name => <option key={name}>{name}</option>)}
        </select></label>
        <p className="muted">1 request to {provider}.</p>
        <div><Button type="button" variant="outline" size="sm" disabled={disabled || state.busy || !role || !text}
          onClick={() => state.run(signal => api<{ questions: string[] }>("authoring/questions", "POST",
            { provider, role, description: text }, signal), result => task.append(result.questions))}>
          <WandSparkles/>{state.busy ? "Generating…" : "Draft questions"}
        </Button></div>
      </>}
      {state.busy && <div><Button type="button" size="sm" variant="ghost" onClick={state.cancel}>Discard pending output</Button></div>}
      {state.notice && <p role="status" className="notice">{state.notice}</p>}
    </div>}
  </details>
}
