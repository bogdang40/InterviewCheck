"use client"

import { useState } from "react"
import { ShieldAlert, ShieldCheck } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { extractApiError } from "@/lib/adminModels"

export type AuditChainVerification = {
  ok: boolean
  verifiedCount: number
  legacyUnchainedCount: number
  firstBrokenId: number | null
  headHash: string | null
}

const VERIFY_PATHS = ["/api/integrations/admin/audit/verify", "/api/admin/audit/verify"] as const

export function AuditIntegrityBanner({ onAuthInvalid }: { onAuthInvalid: (msg: string) => void }) {
  const [result, setResult] = useState<AuditChainVerification | null>(null)
  const [unsupported, setUnsupported] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")

  async function verifyChain() {
    setBusy(true); setError(""); setUnsupported(false)
    try {
      for (const path of VERIFY_PATHS) {
        const res = await fetch(path, {
          method: "GET",
          credentials: "include",
          cache: "no-store",
          headers: { "X-InterviewCheck": "1" },
        })
        const data = await res.json().catch(() => null)
        if (res.status === 401 || res.status === 403) {
          onAuthInvalid(extractApiError(data, res.status))
          return
        }
        if (res.status === 404 || res.status === 501 || (res.status === 503 && path === VERIFY_PATHS[0])) continue
        if (!res.ok) {
          setError(extractApiError(data, res.status))
          return
        }
        setResult(data as AuditChainVerification)
        return
      }
      setUnsupported(true)
      setResult(null)
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not verify audit hash chain.")
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="panel inset stack" role="region" aria-label="Audit log hash chain">
      <div className="spread">
        <div className="admin-model-title">
          {result && !result.ok ? <ShieldAlert size={16} aria-hidden="true" /> : <ShieldCheck size={16} aria-hidden="true" />}
          <strong>Audit log hash chain</strong>
          {unsupported ? (
            <Badge variant="secondary">Unavailable</Badge>
          ) : result ? (
            <Badge variant={result.ok ? "success" : "destructive"} className="admin-chain-badge">
              {result.ok ? "Verified" : "Tampered"}
            </Badge>
          ) : (
            <Badge variant="secondary">Not checked</Badge>
          )}
        </div>
        <Button type="button" variant="outline" size="sm" disabled={busy} onClick={() => void verifyChain()}>
          {busy ? "Verifying..." : "Verify hash chain"}
        </Button>
      </div>
      {error && <p role="alert" className="error">{error}</p>}
      {unsupported ? (
        <p className="muted">Audit hash-chain verification is not enabled on this server.</p>
      ) : result ? (
        <p className={result.ok ? "muted admin-chain-badge" : "error admin-chain-badge"}>
          {result.ok
            ? `Verified ${result.verifiedCount} chained ${result.verifiedCount === 1 ? "entry" : "entries"}${result.legacyUnchainedCount > 0 ? `, ${result.legacyUnchainedCount} legacy unchained` : ""}.${result.headHash ? ` Head: ${result.headHash.slice(0, 12)}` : ""}`
            : `Hash-chain mismatch at entry #${result.firstBrokenId ?? "unknown"} (${result.verifiedCount} verified before break).`}
        </p>
      ) : (
        <p className="muted">Check SHA-256 continuity across recorded audit log entries.</p>
      )}
    </div>
  )
}
