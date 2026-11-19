"use client"

import { useEffect, useState } from "react"
import { Settings2 } from "lucide-react"
import { integration } from "@/lib/integrations"
import WorkspaceError from "./WorkspaceError"
import "./ConnectionCatalog.css"

type State = "local" | "configured" | "needs_setup" | "remote"
type Variable = { name: string; present: boolean }
type Operation = {
  name: string
  task: string
  where: string
  state: State
  alternatives: Variable[][]
  optional: Variable[]
}
type Provider = { id: string; name: string; operations: Operation[] }
const labels: Record<State, string> = {
  local: "Ready locally",
  configured: "Configured",
  needs_setup: "Needs setup",
  remote: "Managed by account service",
}

function RequiredVariables({ operation }: { operation: Operation }) {
  return (
    <div className="catalog-variables">
      {operation.alternatives.map((group, i) => (
        <div key={i}>
          <p>{i === 0 ? "Required settings" : "Or configure this group"}</p>
          <ul>
            {group.map((variable) => (
              <li key={variable.name}>
                <code>{variable.name}</code>
                <span>{variable.present ? "Present" : "Missing"}</span>
              </li>
            ))}
          </ul>
        </div>
      ))}
      {operation.optional.length > 0 && (
        <div>
          <p>Optional settings</p>
          <ul>
            {operation.optional.map((variable) => (
              <li key={variable.name}>
                <code>{variable.name}</code>
                <span>{variable.present ? "Present" : "Unset"}</span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  )
}

export default function ConnectionCatalog() {
  const [providers, setProviders] = useState<Provider[]>([])
  const [query, setQuery] = useState("")
  const [task, setTask] = useState("")
  const [selected, setSelected] = useState("files")
  const [error, setError] = useState("")
  const [revision, setRevision] = useState(0)
  useEffect(() => {
    const controller = new AbortController()
    setError("")
    integration<{ providers: Provider[] }>("catalog", { signal: controller.signal })
      .then((data) => {
        if (!controller.signal.aborted) setProviders(data.providers)
      })
      .catch((error) => {
        if (!controller.signal.aborted) setError(error.message)
      })
    return () => controller.abort()
  }, [revision])
  const tasks = Array.from(new Set(providers.flatMap((item) => item.operations.map((op) => op.task)))).sort()
  const tokens = query.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean)
  const matching = providers
    .map((provider) => ({
      ...provider,
      operations: provider.operations.filter((op) => {
        const text = [provider.name, provider.id, op.name, op.task].join(" ").toLocaleLowerCase()
        return (!task || op.task === task) && tokens.every((token) => text.includes(token))
      }),
    }))
    .filter((provider) => provider.operations.length)
  const current = matching.find((p) => p.id === selected) ?? matching[0]
  return (
    <section className="panel catalog-panel" aria-labelledby="connection-catalog-title">
      <header>
        <div>
          <h2 id="connection-catalog-title">
            <Settings2 size={18} aria-hidden="true" />
            Connection setup
          </h2>
          <p>
            Set the required variables in the FastAPI environment and restart the server. Configured means
            settings are present. Run the operation to check vendor access.
          </p>
        </div>
        <a href="#connection-import">Go to imports and sync</a>
      </header>
      {error ? (
        <WorkspaceError text={error} retry={() => setRevision((value) => value + 1)} />
      ) : !providers.length ? (
        <p role="status">Loading connection setup…</p>
      ) : (
        <>
          <div className="catalog-filters">
            <label className="field">
              Search provider or task
              <input
                type="search"
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                placeholder="Provider or operation"
              />
            </label>
            <label className="field">
              Connection task
              <select value={task} onChange={(e) => setTask(e.target.value)}>
                <option value="">All tasks</option>
                {tasks.map((name) => (
                  <option key={name}>{name}</option>
                ))}
              </select>
            </label>
            <label className="field">
              Setup provider
              <select
                value={current?.id ?? ""}
                disabled={!matching.length}
                onChange={(e) => setSelected(e.target.value)}
              >
                {!matching.length && <option value="">No matching providers</option>}
                {matching.map((provider) => (
                  <option key={provider.id} value={provider.id}>
                    {provider.name}
                  </option>
                ))}
              </select>
            </label>
          </div>
          <p className="catalog-count" role="status">
            {matching.length} {matching.length === 1 ? "provider" : "providers"} available for this search
          </p>
          {current && (
            <section className="catalog-provider" aria-label={current.name + " setup"}>
              <h3>{current.name}</h3>
              {current.operations.map((op) => (
                <details className="catalog-operation" key={current.id + op.name}>
                  <summary>
                    <span>{op.name}</span>
                    <span className={"catalog-state " + op.state}>{labels[op.state]}</span>
                  </summary>
                  <p>Use in {op.where}.</p>
                  {op.state === "remote" && (
                    <p>
                      Billing configuration belongs to the account service. Its Stripe settings are
                      unavailable in this workspace.
                    </p>
                  )}
                  <RequiredVariables operation={op} />
                </details>
              ))}
            </section>
          )}
        </>
      )}
    </section>
  )
}
