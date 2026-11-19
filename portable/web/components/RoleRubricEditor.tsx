"use client"

import { Plus, Trash2 } from "lucide-react"
import type { RubricCriterion } from "@/lib/roleCalibration"
import RoleRubricTemplates from "./RoleRubricTemplates"
import { Badge } from "./ui/badge"
import { Button } from "./ui/button"
import { Input } from "./ui/input"
import { Textarea } from "./ui/textarea"

type Props = {
  rubric: RubricCriterion[]
  changeNote: string
  disabled?: boolean
  onRubric: (next: RubricCriterion[]) => void
  onChangeNote: (note: string) => void
}

function clampWeight(raw: string): number {
  const parsed = Number.parseInt(raw, 10)
  if (!Number.isFinite(parsed)) return 1
  return Math.min(100, Math.max(1, parsed))
}

function splitLines(raw: string): string[] {
  if (!raw) return []
  return raw.split("\n").slice(0, 20).map((line) => line.slice(0, 500))
}

export function sanitizeRubric(items: RubricCriterion[]): RubricCriterion[] {
  return items.slice(0, 25).map((item) => ({
    id: item.id.trim() || crypto.randomUUID(),
    criterion: item.criterion.trim().slice(0, 500),
    weight: Math.min(100, Math.max(1, Math.trunc(Number(item.weight) || 1))),
    expected_signals: item.expected_signals.map((s) => s.trim()).filter(Boolean).slice(0, 20),
    red_flags: item.red_flags.map((s) => s.trim()).filter(Boolean).slice(0, 20),
  }))
}

export default function RoleRubricEditor({
  rubric,
  changeNote,
  disabled = false,
  onRubric,
  onChangeNote,
}: Props) {
  const totalWeight = rubric.reduce((sum, item) => sum + (Number(item.weight) || 0), 0)

  function updateItem(index: number, patch: Partial<RubricCriterion>) {
    onRubric(rubric.map((item, idx) => (idx === index ? { ...item, ...patch } : item)))
  }

  function addCriterion() {
    if (rubric.length >= 25) return
    onRubric([
      ...rubric,
      {
        id: crypto.randomUUID(),
        criterion: "",
        weight: 25,
        expected_signals: [],
        red_flags: [],
      },
    ])
  }

  function removeCriterion(index: number) {
    onRubric(rubric.filter((_, idx) => idx !== index))
  }

  return (
    <fieldset className="source-box stack">
      <legend>Structured rubric criteria</legend>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="muted text-sm">
          Define weighted criteria, expected signals, and red flags stored with each role version.
        </p>
        <div className="flex flex-wrap items-center gap-2">
          <Badge variant="secondary">{rubric.length} / 25 criteria</Badge>
          {rubric.length > 0 && <Badge variant="outline">Total weight {totalWeight}</Badge>}
        </div>
      </div>

      <RoleRubricTemplates
        currentCount={rubric.length}
        disabled={disabled}
        onReplace={(items) => onRubric(items)}
        onAppend={(items) => onRubric([...rubric, ...items].slice(0, 25))}
      />

      {rubric.map((item, index) => (
        <fieldset className="stack rounded-md border border-[var(--line)] bg-[var(--surface)] p-3" key={item.id}>
          <legend className="px-1 font-mono text-xs text-[var(--muted)]">
            Criterion {index + 1}
          </legend>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-[minmax(0,1fr)_130px]">
            <label className="field">
              Criterion title
              <Input
                value={item.criterion}
                maxLength={500}
                required
                disabled={disabled}
                placeholder="e.g. Concurrency and lock ordering"
                onChange={(e) => updateItem(index, { criterion: e.target.value })}
              />
            </label>
            <label className="field">
              Weight (1 to 100)
              <Input
                type="number"
                min={1}
                max={100}
                step={1}
                required
                disabled={disabled}
                value={item.weight === 0 ? "" : item.weight}
                onChange={(e) => {
                  const raw = e.target.value.trim()
                  updateItem(index, { weight: raw === "" ? 0 : clampWeight(raw) })
                }}
                onBlur={() => {
                  if (item.weight < 1) updateItem(index, { weight: 1 })
                }}
              />
            </label>
          </div>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <label className="field">
              Expected signals, one per line
              <Textarea
                rows={3}
                disabled={disabled}
                value={item.expected_signals.join("\n")}
                placeholder="States lock ordering invariant&#10;Explains failure tradeoff"
                onChange={(e) => updateItem(index, { expected_signals: splitLines(e.target.value) })}
              />
            </label>
            <label className="field">
              Red flags, one per line
              <Textarea
                rows={3}
                disabled={disabled}
                value={item.red_flags.join("\n")}
                placeholder="Ignores deadlock risk"
                onChange={(e) => updateItem(index, { red_flags: splitLines(e.target.value) })}
              />
            </label>
          </div>
          <div>
            <Button
              type="button"
              variant="ghost"
              size="sm"
              disabled={disabled}
              aria-label={`Remove criterion ${index + 1}`}
              onClick={() => removeCriterion(index)}
            >
              <Trash2 aria-hidden="true" />
              Remove criterion
            </Button>
          </div>
        </fieldset>
      ))}

      <div className="flex flex-wrap items-center gap-2">
        <Button
          type="button"
          variant="outline"
          size="sm"
          disabled={disabled || rubric.length >= 25}
          onClick={addCriterion}
        >
          <Plus aria-hidden="true" />
          Add rubric criterion
        </Button>
        {rubric.length >= 25 && <small className="muted">Maximum 25 criteria reached.</small>}
      </div>

      <label className="field">
        Version change note
        <Input
          value={changeNote}
          maxLength={300}
          disabled={disabled}
          placeholder="Optional summary for version history (e.g. Added system design rubric)"
          onChange={(e) => onChangeNote(e.target.value)}
        />
      </label>
    </fieldset>
  )
}
