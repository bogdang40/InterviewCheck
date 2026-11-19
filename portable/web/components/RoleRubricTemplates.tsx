"use client"

import { useEffect, useState } from "react"
import { Layers, Plus, RefreshCw } from "lucide-react"
import type { RubricCriterion } from "@/lib/roleCalibration"
import { fetchRubricTemplates, rubricCriteriaFromTemplate, type RubricTemplate } from "@/lib/roleTemplates"
import { Badge } from "./ui/badge"
import { Button } from "./ui/button"

type Props = {
  currentCount: number
  disabled?: boolean
  onReplace: (items: RubricCriterion[]) => void
  onAppend: (items: RubricCriterion[]) => void
}

export default function RoleRubricTemplates({ currentCount, disabled = false, onReplace, onAppend }: Props) {
  const [templates, setTemplates] = useState<RubricTemplate[]>([])
  const [selectedId, setSelectedId] = useState("")
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState("")
  const [notice, setNotice] = useState("")
  const [reloadNonce, setReloadNonce] = useState(0)

  useEffect(() => {
    const controller = new AbortController()
    setLoading(true)
    setError("")
    fetchRubricTemplates(controller.signal)
      .then((items) => {
        setTemplates(items)
        setSelectedId((prev) => (prev && items.some((t) => t.id === prev) ? prev : ""))
      })
      .catch((err) => {
        if (!(err instanceof DOMException && err.name === "AbortError")) {
          setError(err instanceof Error ? err.message : "Could not load rubric templates.")
        }
      })
      .finally(() => {
        if (!controller.signal.aborted) setLoading(false)
      })
    return () => controller.abort()
  }, [reloadNonce])

  const selected = templates.find((t) => t.id === selectedId) ?? null
  const previewWeight = selected ? selected.rubric.reduce((sum, item) => sum + (Number(item.weight) || 0), 0) : 0
  const remainingSlots = Math.max(0, 25 - currentCount)

  function handleReplace() {
    if (!selected || disabled) return
    const items = rubricCriteriaFromTemplate(selected)
    onReplace(items)
    setNotice(`Replaced rubric with ${selected.title} (${items.length} criteria).`)
  }

  function handleAppend() {
    if (!selected || disabled || remainingSlots === 0) return
    const items = rubricCriteriaFromTemplate(selected).slice(0, remainingSlots)
    onAppend(items)
    setNotice(`Appended ${items.length} criteria from ${selected.title}.`)
  }

  return (
    <div className="rounded-md border border-[var(--line)] bg-[var(--subtle)] p-3 stack" aria-label="Rubric template picker">
      <label className="field min-w-[220px]">
        Rubric template library
        <select
          aria-label="Rubric template"
          value={selectedId}
          disabled={disabled || loading || templates.length === 0}
          onChange={(e) => { setSelectedId(e.target.value); setNotice("") }}
        >
          <option value="">{loading ? "Loading rubric templates..." : "Choose a rubric template..."}</option>
          {templates.map((tpl) => (
            <option key={tpl.id} value={tpl.id}>{tpl.title} ({tpl.category})</option>
          ))}
        </select>
      </label>

      {error && (
        <div className="flex flex-wrap items-center justify-between gap-2">
          <p role="alert" className="error text-sm">{error}</p>
          <Button type="button" variant="outline" size="sm" className="min-h-[44px] md:min-h-8" disabled={disabled || loading} onClick={() => setReloadNonce((n) => n + 1)}>
            <RefreshCw className="size-3.5" aria-hidden="true" />
            Retry templates
          </Button>
        </div>
      )}

      {selected && (
        <div className="stack !gap-2 rounded-md border border-[var(--line)] bg-[var(--surface)] p-3">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <strong className="text-sm">{selected.title}</strong>
            <div className="flex flex-wrap items-center gap-1.5">
              <Badge variant="secondary">{selected.rubric.length} criteria</Badge>
              <Badge variant="outline">Total weight {previewWeight}</Badge>
            </div>
          </div>
          {selected.summary && <p className="muted text-xs">{selected.summary}</p>}
          <ul className="m-0 list-none space-y-1 p-0 text-xs">
            {selected.rubric.map((item, idx) => (
              <li key={`${selected.id}-${idx}`} className="flex flex-wrap items-center justify-between gap-2 rounded border border-[var(--line)] px-2.5 py-1.5">
                <span className="font-medium break-words">{item.criterion}</span>
                <span className="font-mono text-[var(--muted)]">
                  weight {item.weight} | {item.expected_signals.length} signals | {item.red_flags.length} flags
                </span>
              </li>
            ))}
          </ul>
          <div className="flex flex-wrap items-center gap-2 pt-1">
            <Button type="button" variant="outline" size="sm" className="min-h-[44px] md:min-h-8" disabled={disabled} onClick={handleReplace}>
              <Layers className="size-3.5" aria-hidden="true" />
              Replace criteria
            </Button>
            <Button type="button" variant="outline" size="sm" className="min-h-[44px] md:min-h-8" disabled={disabled || remainingSlots === 0} onClick={handleAppend}>
              <Plus className="size-3.5" aria-hidden="true" />
              Append criteria
            </Button>
            {remainingSlots === 0 && <small className="muted">Maximum 25 criteria reached; remove one before appending.</small>}
          </div>
        </div>
      )}

      {notice && <p role="status" aria-live="polite" className="text-xs text-[var(--success-text)]">{notice}</p>}
    </div>
  )
}
