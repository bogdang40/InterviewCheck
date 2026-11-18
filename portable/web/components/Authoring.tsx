import { useEffect, useState } from "react"
import { WandSparkles } from "lucide-react"
import { Button } from "./ui/button"
import { api, message, type Source } from "@/lib/api"

type Task =
  | {
      mode: "questions"
      inputs: () => { role: string; description: string }
      append: (questions: string[]) => void
    }
  | { mode: "reference"; inputs: () => { role: string; question: string }; append: (source: Source) => void }

export default function Authoring({
  task,
  disabled = false,
  pending,
}: {
  task: Task
  disabled?: boolean
  pending?: (value: boolean) => void
}) {
  const [providers, setProviders] = useState<string[]>([])
  const [provider, setProvider] = useState(""),
    [style, setStyle] = useState("Spoken answer")
  const [busy, setBusy] = useState(false),
    [error, setError] = useState("")
  useEffect(() => {
    let active = true
    api<string[]>("authoring/providers")
      .then((list) => {
        if (active) {
          setProviders(list)
          setProvider(list[0] ?? "")
        }
      })
      .catch((e) => {
        if (active) setError(message(e))
      })
    return () => {
      active = false
    }
  }, [])
  async function generate() {
    setBusy(true)
    pending?.(true)
    setError("")
    try {
      const values = task.inputs()
      if (Object.values(values).some((v) => !v.trim()))
        throw new Error(
          task.mode === "questions" ? "Enter the role and job description first." : "Enter a question first.",
        )
      if (task.mode === "questions") {
        const result = await api<{ questions: string[] }>("authoring/questions", "POST", {
          provider,
          ...values,
        })
        task.append(result.questions)
      } else {
        task.append(await api<Source>("authoring/reference", "POST", { provider, style, ...values }))
      }
    } catch (e) {
      setError(message(e))
    } finally {
      setBusy(false)
      pending?.(false)
    }
  }
  if (!providers.length && !error) return null
  return (
    <details className="import">
      <summary>{task.mode === "questions" ? "Draft role questions" : "Generate a reference answer"}</summary>
      <div className="stack">
        {providers.length > 0 && (
          <>
            <div className="dual">
              <label className="field">
                Provider
                <select disabled={busy} value={provider} onChange={(e) => setProvider(e.target.value)}>
                  {providers.map((p) => (
                    <option key={p}>{p}</option>
                  ))}
                </select>
              </label>
              {task.mode === "reference" && (
                <label className="field">
                  Answer format
                  <select disabled={busy} value={style} onChange={(e) => setStyle(e.target.value)}>
                    {["Spoken answer", "Talking points", "Worked example"].map((s) => (
                      <option key={s}>{s}</option>
                    ))}
                  </select>
                </label>
              )}
            </div>
            <p className="muted">
              {task.mode === "questions"
                ? "This sends the role and job description"
                : "This sends the role and question"}{" "}
              to {provider}.
            </p>
            <div>
              <Button
                type="button"
                variant="outline"
                size="sm"
                disabled={busy || disabled}
                onClick={generate}
              >
                <WandSparkles />
                {busy ? "Generating…" : task.mode === "questions" ? "Draft questions" : "Generate reference"}
              </Button>
            </div>
          </>
        )}
        {error && (
          <p role="alert" className="error">
            {error}
          </p>
        )}
      </div>
    </details>
  )
}
