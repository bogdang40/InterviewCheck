"use client"

import { useEffect, useState } from "react"
import { api, type Answer, type Source } from "./api"
import { integration, type ProviderStatus } from "./integrations"
import { ACCOUNT_EVENT } from "./useAccountStatus"

export type ScoringCapabilities = { embedding: boolean; judge: boolean; loaded: boolean }
export type SemanticMatch = { source_index: number; label: string; cosine: number }
export type SemanticScoreResult = {
  available: boolean
  reason?: string
  provider?: string
  model?: string
  matches: SemanticMatch[]
}
export type JudgeReviewResult =
  | { status: "insufficient_evidence"; follow_up_questions: string[] }
  | { status: "reviewed"; provider: string; model: string; follow_up_questions: string[] }

const PROVIDER_NAMES: Record<string, string> = {
  openai: "OpenAI",
  anthropic: "Anthropic",
  azure_openai: "Azure OpenAI",
  openai_compatible: "OpenAI-compatible",
}

export function formatScoringModel(provider?: string, model?: string): string {
  const label = provider ? PROVIDER_NAMES[provider] ?? provider : ""
  return [label, model].filter(Boolean).join(" · ")
}

export async function fetchScoringCapabilities(signal?: AbortSignal): Promise<{ embedding: boolean; judge: boolean }> {
  const status = await integration<ProviderStatus>("status", { signal })
  return { embedding: status.embedding === true, judge: status.judge === true }
}

export function useScoringCapabilities(enabled = true): ScoringCapabilities {
  const [state, setState] = useState<ScoringCapabilities>({ embedding: false, judge: false, loaded: !enabled })
  const [tick, setTick] = useState(0)

  useEffect(() => {
    if (!enabled) return
    const onAccount = () => setTick((n) => n + 1)
    window.addEventListener(ACCOUNT_EVENT, onAccount)
    return () => window.removeEventListener(ACCOUNT_EVENT, onAccount)
  }, [enabled])

  useEffect(() => {
    if (!enabled) return
    const controller = new AbortController()
    fetchScoringCapabilities(controller.signal)
      .then((caps) => {
        if (!controller.signal.aborted) setState({ ...caps, loaded: true })
      })
      .catch(() => {
        if (!controller.signal.aborted) setState({ embedding: false, judge: false, loaded: true })
      })
    return () => controller.abort()
  }, [enabled, tick])

  return state
}

export function runSemanticSimilarity(
  answer: string,
  sources: Source[],
  signal?: AbortSignal,
): Promise<SemanticScoreResult> {
  const references = sources
    .filter((s) => s.label.trim() && s.text.trim())
    .slice(0, 12)
    .map(({ label, text, permitted }) => ({ label, text, permitted }))
  return api<SemanticScoreResult>("scoring/semantic", "POST", { answer, references }, signal)
}

export async function runJudgeCheck(sessionId: string, item: Answer, signal?: AbortSignal): Promise<JudgeReviewResult> {
  const passages = item.result.passages.slice(0, 3).map(p => [p.answer_excerpt, p.source_excerpt])
  const evidence = new TextEncoder().encode(JSON.stringify([item.question, passages]))
  if (!globalThis.crypto?.subtle) throw new Error("Open the workspace on HTTPS or localhost to verify the saved evidence.")
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", evidence))
  return api<JudgeReviewResult>(
    "scoring/judge/saved",
    "POST",
    {
      session_id: sessionId,
      answer_id: item.id,
      expected_revision: item.revision,
      evidence_sha256: Array.from(digest, byte => byte.toString(16).padStart(2, "0")).join(""),
    },
    signal,
  )
}
