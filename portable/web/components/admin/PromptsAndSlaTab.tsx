"use client"

import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from "react"
import { Activity, FileText, RefreshCw, RotateCcw, SlidersHorizontal } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Textarea } from "@/components/ui/textarea"
import { AdminApiError, CAPABILITY_LABELS, type ConnectedModel, type ModelCapability } from "@/lib/adminModels"
import {
  PROMPT_SLOTS, PROMPT_SLOT_LABELS, getModelsSla, listPromptTemplates, listPromptVersions,
  resetModelCircuit, rollbackPromptTemplate, updateCircuitPolicy, updatePromptTemplate,
  type CircuitState, type ModelSlaRow, type PromptSlot, type PromptTemplate, type PromptVersion, type SlaFleetSummary,
} from "@/lib/adminPromptsSla"
import { formatLatency } from "@/lib/adminTelemetry"
import styles from "./PromptsAndSlaTab.module.css"

const CIRCUIT_BADGE: Record<CircuitState, { label: string; variant: "success" | "destructive" | "warning" }> = {
  closed: { label: "Closed", variant: "success" },
  open: { label: "Open", variant: "destructive" },
  half_open: { label: "Half-open", variant: "warning" },
}
const fmtPct = (v: number | null | undefined) => (v === null || v === undefined || !Number.isFinite(v) ? "n/a" : `${v.toFixed(1)}%`)
const fmtDate = (iso: string | null | undefined) => (!iso ? "n/a" : Number.isNaN(new Date(iso).getTime()) ? iso : new Date(iso).toLocaleString())

function UnifiedDiffView({ diff }: { diff: string }) {
  if (!diff.trim()) return <p className="muted">No changes in this diff view.</p>
  return (
    <pre className={styles.diffBox}>
      {diff.split("\n").map((line, i) => {
        const cls = line.startsWith("+") && !line.startsWith("+++") ? styles.diffAdd
          : line.startsWith("-") && !line.startsWith("---") ? styles.diffDel
            : line.startsWith("@@") ? styles.diffHunk : ""
        return <span key={i} className={`${styles.diffLine}${cls ? ` ${cls}` : ""}`}>{line || " "}</span>
      })}
    </pre>
  )
}

export function PromptsAndSlaTab({ models, onAuthInvalid }: { models: ConnectedModel[]; onAuthInvalid: (msg: string) => void }) {
  const modelById = useMemo(() => new Map(models.map((m) => [m.id, m])), [models])
  const [slaAvailable, setSlaAvailable] = useState(true)
  const [slaLoading, setSlaLoading] = useState(true)
  const [slaError, setSlaError] = useState("")
  const [slaSummary, setSlaSummary] = useState<SlaFleetSummary | null>(null)
  const [slaRows, setSlaRows] = useState<ModelSlaRow[]>([])
  const [editingPolicy, setEditingPolicy] = useState<ModelSlaRow | null>(null)
  const [thresholdRaw, setThresholdRaw] = useState("3")
  const [cooldownRaw, setCooldownRaw] = useState("60")
  const [slaTargetRaw, setSlaTargetRaw] = useState("2500")
  const [promptsAvailable, setPromptsAvailable] = useState(true)
  const [promptsLoading, setPromptsLoading] = useState(true)
  const [promptsError, setPromptsError] = useState("")
  const [conflictMsg, setConflictMsg] = useState("")
  const [templates, setTemplates] = useState<PromptTemplate[]>([])
  const [selectedSlot, setSelectedSlot] = useState<PromptSlot>("question_planning")
  const [versions, setVersions] = useState<PromptVersion[]>([])
  const [versionsLoading, setVersionsLoading] = useState(false)
  const [diffMode, setDiffMode] = useState<"prev" | "active">("prev")
  const [systemPrompt, setSystemPrompt] = useState("")
  const [outputRule, setOutputRule] = useState("")
  const [changeNote, setChangeNote] = useState("")
  const [busyKey, setBusyKey] = useState<string | null>(null)
  const [statusMsg, setStatusMsg] = useState("")

  const onAuthInvalidRef = useRef(onAuthInvalid)
  onAuthInvalidRef.current = onAuthInvalid
  const selectedSlotRef = useRef<PromptSlot>(selectedSlot)
  selectedSlotRef.current = selectedSlot
  const mountedRef = useRef(false)
  const slaAbortRef = useRef<AbortController | null>(null)
  const promptsAbortRef = useRef<AbortController | null>(null)
  const versionsAbortRef = useRef<AbortController | null>(null)
  const slaSeqRef = useRef(0)
  const promptsSeqRef = useRef(0)
  const versionsSeqRef = useRef(0)

  const checkAuth = useCallback((err: unknown): boolean => {
    if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) { onAuthInvalidRef.current(err.message); return true }
    return false
  }, [])

  const loadSla = useCallback(async () => {
    slaAbortRef.current?.abort()
    const controller = new AbortController()
    slaAbortRef.current = controller
    const seq = ++slaSeqRef.current
    setSlaLoading(true); setSlaError("")
    try {
      const res = await getModelsSla()
      if (!mountedRef.current || controller.signal.aborted || seq !== slaSeqRef.current) return
      setSlaAvailable(res.available); setSlaSummary(res.summary); setSlaRows(res.models)
    } catch (err) {
      if (!mountedRef.current || controller.signal.aborted || seq !== slaSeqRef.current) return
      if (!checkAuth(err)) setSlaError(err instanceof Error ? err.message : "Could not load SLA metrics.")
    } finally {
      if (mountedRef.current && !controller.signal.aborted && seq === slaSeqRef.current) setSlaLoading(false)
    }
  }, [checkAuth])

  const loadSlotVersions = useCallback(async (slot: PromptSlot) => {
    versionsAbortRef.current?.abort()
    const controller = new AbortController()
    versionsAbortRef.current = controller
    const seq = ++versionsSeqRef.current
    setVersionsLoading(true)
    try {
      const res = await listPromptVersions(slot)
      if (!mountedRef.current || controller.signal.aborted || seq !== versionsSeqRef.current) return
      setPromptsAvailable(res.available); setVersions(res.versions)
      if (res.template) {
        setTemplates((prev) => prev.map((t) => (t.slot === slot ? res.template! : t)))
        if (selectedSlotRef.current === slot) {
          setSystemPrompt(res.template.system_prompt); setOutputRule(res.template.output_rule)
        }
      }
    } catch (err) {
      if (!mountedRef.current || controller.signal.aborted || seq !== versionsSeqRef.current) return
      if (!checkAuth(err)) setPromptsError(err instanceof Error ? err.message : "Could not load version history.")
    } finally {
      if (mountedRef.current && !controller.signal.aborted && seq === versionsSeqRef.current) setVersionsLoading(false)
    }
  }, [checkAuth])

  const loadPrompts = useCallback(async () => {
    promptsAbortRef.current?.abort()
    const controller = new AbortController()
    promptsAbortRef.current = controller
    const seq = ++promptsSeqRef.current
    setPromptsLoading(true); setPromptsError(""); setConflictMsg("")
    try {
      const res = await listPromptTemplates()
      if (!mountedRef.current || controller.signal.aborted || seq !== promptsSeqRef.current) return
      setPromptsAvailable(res.available); setTemplates(res.prompts)
      const currentSlot = selectedSlotRef.current
      const active = res.prompts.find((p) => p.slot === currentSlot) ?? res.prompts[0]
      if (active) {
        if (active.slot !== currentSlot) {
          selectedSlotRef.current = active.slot
          setSelectedSlot(active.slot)
        }
        setSystemPrompt(active.system_prompt); setOutputRule(active.output_rule)
        await loadSlotVersions(active.slot)
      }
    } catch (err) {
      if (!mountedRef.current || controller.signal.aborted || seq !== promptsSeqRef.current) return
      if (!checkAuth(err)) setPromptsError(err instanceof Error ? err.message : "Could not load prompt templates.")
    } finally {
      if (mountedRef.current && !controller.signal.aborted && seq === promptsSeqRef.current) setPromptsLoading(false)
    }
  }, [checkAuth, loadSlotVersions])

  useEffect(() => {
    mountedRef.current = true
    void loadSla()
    void loadPrompts()
    return () => {
      mountedRef.current = false
      slaAbortRef.current?.abort()
      promptsAbortRef.current?.abort()
      versionsAbortRef.current?.abort()
    }
  }, [loadSla, loadPrompts])
  const activeTemplate = templates.find((t) => t.slot === selectedSlot) ?? null

  async function handleResetCircuit(row: ModelSlaRow) {
    setBusyKey(`reset:${row.model_id}`); setSlaError(""); setStatusMsg("")
    try {
      await resetModelCircuit(row.model_id)
      if (!mountedRef.current) return
      setStatusMsg(`Circuit reset to closed for ${modelById.get(row.model_id)?.display_name ?? row.display_name}.`)
      await loadSla()
    } catch (err) {
      if (mountedRef.current && !checkAuth(err)) setSlaError(err instanceof Error ? err.message : "Could not reset circuit.")
    } finally { if (mountedRef.current) setBusyKey(null) }
  }

  function openPolicyEditor(row: ModelSlaRow) {
    setEditingPolicy(row); setThresholdRaw(String(row.circuit.consecutive_threshold))
    setCooldownRaw(String(row.circuit.cooldown_seconds)); setSlaTargetRaw(String(row.sla_target_ms)); setSlaError("")
  }

  async function handleSavePolicy(e: FormEvent<HTMLFormElement>) {
    e.preventDefault(); if (!editingPolicy) return
    const thr = Number.parseInt(thresholdRaw, 10), cd = Number.parseInt(cooldownRaw, 10), tgt = Number.parseInt(slaTargetRaw, 10)
    if (!Number.isInteger(thr) || thr < 1 || thr > 20) { setSlaError("Failure threshold must be 1 to 20."); return }
    if (!Number.isInteger(cd) || cd < 5 || cd > 3600) { setSlaError("Cooldown must be 5 to 3600 seconds."); return }
    if (!Number.isInteger(tgt) || tgt < 100 || tgt > 60000) { setSlaError("SLA target must be 100 to 60000 ms."); return }
    setBusyKey(`policy:${editingPolicy.model_id}`); setSlaError(""); setStatusMsg("")
    try {
      await updateCircuitPolicy(editingPolicy.model_id, { consecutive_threshold: thr, cooldown_seconds: cd, sla_target_ms: tgt })
      if (!mountedRef.current) return
      setStatusMsg(`Updated circuit policy and SLA target for ${editingPolicy.display_name}.`)
      setEditingPolicy(null); await loadSla()
    } catch (err) {
      if (mountedRef.current && !checkAuth(err)) setSlaError(err instanceof Error ? err.message : "Could not update circuit policy.")
    } finally { if (mountedRef.current) setBusyKey(null) }
  }

  function handleSlotChange(slot: PromptSlot) {
    selectedSlotRef.current = slot
    setSelectedSlot(slot); setConflictMsg(""); setPromptsError(""); setChangeNote("")
    const found = templates.find((t) => t.slot === slot)
    if (found) { setSystemPrompt(found.system_prompt); setOutputRule(found.output_rule) }
    void loadSlotVersions(slot)
  }

  async function handleSavePrompt(e: FormEvent<HTMLFormElement>) {
    e.preventDefault(); if (!activeTemplate) return
    setPromptsError(""); setConflictMsg(""); setStatusMsg("")
    if (systemPrompt.trim().length < 10) { setPromptsError("System prompt must be at least 10 characters."); return }
    if (outputRule.trim().length < 5) { setPromptsError("Output rule must be at least 5 characters."); return }
    setBusyKey("save-prompt")
    try {
      const updated = await updatePromptTemplate(selectedSlot, {
        system_prompt: systemPrompt.trim(), output_rule: outputRule.trim(),
        change_note: changeNote.trim(), expected_version: activeTemplate.active_version,
      })
      if (!mountedRef.current) return
      setTemplates((prev) => prev.map((t) => (t.slot === updated.slot ? updated : t)))
      setChangeNote(""); setStatusMsg(`Saved ${PROMPT_SLOT_LABELS[updated.slot]} as version ${updated.active_version}.`)
      await loadSlotVersions(selectedSlot)
    } catch (err) {
      if (!mountedRef.current || checkAuth(err)) return
      if (err instanceof AdminApiError && err.status === 409) setConflictMsg(err.message)
      else setPromptsError(err instanceof Error ? err.message : "Could not save prompt template.")
    } finally { if (mountedRef.current) setBusyKey(null) }
  }

  async function handleRollback(versionNum: number) {
    if (!activeTemplate) return
    setBusyKey(`rb:${versionNum}`); setPromptsError(""); setConflictMsg(""); setStatusMsg("")
    try {
      const updated = await rollbackPromptTemplate(selectedSlot, {
        target_version: versionNum, expected_version: activeTemplate.active_version,
        change_note: changeNote.trim() || `Rollback to v${versionNum}`,
      })
      if (!mountedRef.current) return
      setTemplates((prev) => prev.map((t) => (t.slot === updated.slot ? updated : t)))
      setChangeNote(""); setStatusMsg(`Rolled back ${PROMPT_SLOT_LABELS[updated.slot]} to v${versionNum} (new v${updated.active_version}).`)
      await loadSlotVersions(selectedSlot)
    } catch (err) {
      if (!mountedRef.current || checkAuth(err)) return
      if (err instanceof AdminApiError && err.status === 409) setConflictMsg(err.message)
      else setPromptsError(err instanceof Error ? err.message : "Could not roll back prompt version.")
    } finally { if (mountedRef.current) setBusyKey(null) }
  }

  const openCircuits = slaSummary
    ? (slaSummary.open_circuits ?? 0) + (slaSummary.half_open_circuits ?? 0)
    : slaRows.filter((r) => r.circuit.state !== "closed").length
  const slaBreaches = slaSummary?.sla_violating_models ?? slaSummary?.sla_breaches ?? slaRows.filter((r) => r.sla_compliant === false).length

  return (
    <div className={styles.tabRoot}>
      {statusMsg && <p role="status" className="notice">{statusMsg}</p>}
      <section className="panel stack" aria-label="Model SLA and circuit breakers" aria-busy={slaLoading}>
        <div className={styles.sectionHead}>
          <div>
            <h2 className="admin-sim-heading"><Activity size={18} aria-hidden="true" />Model SLA &amp; circuit breakers</h2>
            <p className="muted">Track p50, p95, p99 latency, error rates, SLA compliance, and circuit breaker states.</p>
          </div>
          <Button type="button" variant="outline" size="sm" disabled={slaLoading || busyKey !== null} onClick={() => void loadSla()}><RefreshCw size={14} aria-hidden="true" />Refresh SLA</Button>
        </div>
        {slaError && <p role="alert" className="error">{slaError}</p>}
        {!slaAvailable ? <p role="status" className="notice">SLA and circuit breaker endpoints are not enabled on this server yet.</p>
          : slaLoading ? <p className="muted">Loading SLA and circuit telemetry...</p> : (
            <>
              <div className={styles.summaryRow}>
                <div className={`panel inset ${styles.summaryCell}`}><span className="muted">Monitored models</span><strong>{slaSummary?.total_models ?? slaRows.length}</strong></div>
                <div className={`panel inset ${styles.summaryCell}`}><span className="muted">Open / half-open circuits</span><strong>{openCircuits}</strong></div>
                <div className={`panel inset ${styles.summaryCell}`}><span className="muted">SLA breaches</span><strong>{slaBreaches}</strong></div>
                <div className={`panel inset ${styles.summaryCell}`}><span className="muted">Fleet p95 / error rate</span><strong>{formatLatency(slaSummary?.p95_latency_ms)} / {fmtPct(slaSummary?.error_rate_pct)}</strong></div>
              </div>
              {editingPolicy && (
                <form noValidate className={`panel inset ${styles.policyForm}`} onSubmit={(e) => void handleSavePolicy(e)}>
                  <h3><SlidersHorizontal size={15} aria-hidden="true" /> Edit circuit &amp; SLA policy: {editingPolicy.display_name}</h3>
                  <div className={styles.policyGrid}>
                    <label className="field">Failure threshold (1 to 20)<Input type="number" min={1} max={20} value={thresholdRaw} onChange={(e) => setThresholdRaw(e.target.value)} /></label>
                    <label className="field">Cooldown seconds (5 to 3600)<Input type="number" min={5} max={3600} value={cooldownRaw} onChange={(e) => setCooldownRaw(e.target.value)} /></label>
                    <label className="field">SLA target ms (100 to 60000)<Input type="number" min={100} max={60000} value={slaTargetRaw} onChange={(e) => setSlaTargetRaw(e.target.value)} /></label>
                  </div>
                  <div className={styles.actionsRow}><Button type="submit" size="sm" disabled={busyKey !== null}>Save policy</Button><Button type="button" variant="ghost" size="sm" disabled={busyKey !== null} onClick={() => setEditingPolicy(null)}>Cancel</Button></div>
                </form>
              )}
              {!slaRows.length ? <p className="muted">No models registered for SLA tracking yet.</p> : (
                <div className="admin-table-wrap"><table className="admin-table">
                  <thead><tr><th scope="col">Model</th><th scope="col">p50</th><th scope="col">p95</th><th scope="col">p99</th><th scope="col">Error rate</th><th scope="col">SLA</th><th scope="col">Circuit</th><th scope="col">Actions</th></tr></thead>
                  <tbody>{slaRows.map((row) => {
                    const known = modelById.get(row.model_id), cb = CIRCUIT_BADGE[row.circuit.state], cap = known?.capability ?? row.capability
                    const displayName = known?.display_name ?? row.display_name
                    return (
                      <tr key={row.model_id}>
                        <td><div className="admin-model-title"><strong>{displayName}</strong>{cap && <Badge variant="secondary">{CAPABILITY_LABELS[cap as ModelCapability] ?? cap}</Badge>}</div>{row.circuit.last_failure_reason && <div className={styles.reasonCell}>{row.circuit.last_failure_reason}</div>}</td>
                        <td className="admin-mono">{formatLatency(row.p50_latency_ms)}</td><td className="admin-mono">{formatLatency(row.p95_latency_ms)}</td><td className="admin-mono">{formatLatency(row.p99_latency_ms)}</td><td className="admin-mono">{fmtPct(row.error_rate_pct)}</td>
                        <td><Badge variant={row.sla_compliant === true ? "success" : row.sla_compliant === false ? "destructive" : "secondary"}>{row.sla_compliant === true ? "Within SLA" : row.sla_compliant === false ? "Breach" : "No data"}</Badge><div className="admin-mono">Target {row.sla_target_ms} ms</div></td>
                        <td><Badge variant={cb.variant}>{cb.label}</Badge><div className="admin-mono">Streak {row.circuit.failure_streak}/{row.circuit.consecutive_threshold} ({row.circuit.cooldown_seconds}s)</div></td>
                        <td><div className={styles.actionsRow}><Button type="button" variant="outline" size="xs" aria-label={`Reset circuit for ${displayName}`} disabled={busyKey !== null || (row.circuit.state === "closed" && row.circuit.failure_streak === 0)} onClick={() => void handleResetCircuit(row)}>Reset circuit</Button><Button type="button" variant="outline" size="xs" aria-label={`Edit policy for ${displayName}`} disabled={busyKey !== null} onClick={() => openPolicyEditor(row)}>Edit policy</Button></div></td>
                      </tr>
                    )
                  })}</tbody>
                </table></div>
              )}
            </>
          )}
      </section>

      <section className="panel stack" aria-label="Prompt templates" aria-busy={promptsLoading}>
        <div className={styles.sectionHead}>
          <div>
            <h2 className="admin-sim-heading"><FileText size={18} aria-hidden="true" />Prompt template governance</h2>
            <p className="muted">Edit system prompts and output rules with optimistic locking, unified diffs, and rollback.</p>
          </div>
          <Button type="button" variant="outline" size="sm" disabled={promptsLoading || busyKey !== null} onClick={() => void loadPrompts()}><RefreshCw size={14} aria-hidden="true" />Reload prompts</Button>
        </div>
        {promptsError && <p role="alert" className="error">{promptsError}</p>}
        {conflictMsg && <div role="alert" className={`error ${styles.conflictBanner}`}><span>Version conflict (409): {conflictMsg}</span><Button type="button" variant="outline" size="xs" onClick={() => void loadPrompts()}>Reload latest version</Button></div>}
        {!promptsAvailable ? <p role="status" className="notice">Prompt template endpoints are not enabled on this server yet.</p>
          : promptsLoading ? <p className="muted">Loading prompt templates...</p> : (
            <>
              <div className={styles.slotToolbar}>
                <label className="field">Prompt slot<select value={selectedSlot} disabled={busyKey !== null} onChange={(e) => handleSlotChange(e.target.value as PromptSlot)}>{PROMPT_SLOTS.map((s) => <option key={s} value={s}>{PROMPT_SLOT_LABELS[s]} ({s})</option>)}</select></label>
                {activeTemplate && <div className={styles.actionsRow}><Badge variant="default">v{activeTemplate.active_version} active</Badge><Badge variant="outline">{activeTemplate.version_count} versions</Badge><span className="admin-mono">Updated by {activeTemplate.updated_by} ({fmtDate(activeTemplate.updated_at)})</span></div>}
              </div>
              {activeTemplate && (
                <form noValidate className="panel inset stack" onSubmit={(e) => void handleSavePrompt(e)}>
                  <label className="field">System prompt<Textarea rows={4} maxLength={4000} value={systemPrompt} disabled={busyKey !== null} onChange={(e) => setSystemPrompt(e.target.value)} /></label>
                  <label className="field">Output rule<Textarea rows={2} maxLength={500} value={outputRule} disabled={busyKey !== null} onChange={(e) => setOutputRule(e.target.value)} /></label>
                  <label className="field">Change note (optional)<Input maxLength={300} value={changeNote} placeholder="Document why this prompt changed" disabled={busyKey !== null} onChange={(e) => setChangeNote(e.target.value)} /></label>
                  <div className={styles.actionsRow}><Button type="submit" size="sm" disabled={busyKey !== null}>Save new version</Button><Button type="button" variant="ghost" size="sm" disabled={busyKey !== null} onClick={() => { setSystemPrompt(activeTemplate.system_prompt); setOutputRule(activeTemplate.output_rule); setChangeNote("") }}>Discard edits</Button></div>
                </form>
              )}
              <div className="stack" aria-busy={versionsLoading}>
                <div className={styles.sectionHead}>
                  <h3>Version history &amp; unified diff</h3>
                  <div className={styles.actionsRow}><Button type="button" variant={diffMode === "prev" ? "default" : "outline"} size="xs" onClick={() => setDiffMode("prev")}>Diff vs previous</Button><Button type="button" variant={diffMode === "active" ? "default" : "outline"} size="xs" onClick={() => setDiffMode("active")}>Diff vs active</Button></div>
                </div>
                {versionsLoading ? <p className="muted">Loading versions...</p> : !versions.length ? <p className="muted">No saved versions for this slot.</p> : (
                  <div className={styles.versionList}>{versions.map((v) => (
                    <article key={v.id} className={`panel inset ${styles.versionCard}`}>
                      <div className={styles.sectionHead}>
                        <div className="admin-model-title"><strong>v{v.version_number}</strong>{v.is_active && <Badge variant="success">Active</Badge>}<span className="admin-mono">{v.created_by}</span><span className="admin-mono">{fmtDate(v.created_at)}</span></div>
                        {!v.is_active && <Button type="button" variant="outline" size="xs" disabled={busyKey !== null} onClick={() => void handleRollback(v.version_number)}><RotateCcw size={13} aria-hidden="true" />Rollback to v{v.version_number}</Button>}
                      </div>
                      {v.change_note && <p className="muted">{v.change_note}</p>}
                      <UnifiedDiffView diff={diffMode === "prev" ? (v.diff_from_previous || v.diff) : v.diff_vs_active} />
                    </article>
                  ))}</div>
                )}
              </div>
            </>
          )}
      </section>
    </div>
  )
}
