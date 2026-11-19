"use client"

import { useCallback, useEffect, useRef, useState } from "react"
import { KeyRound, RefreshCw, ShieldCheck } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { getModelKeyStatus, rotateModelKeys, type KeyStatusResponse } from "@/lib/adminKeyRotation"
import { AdminApiError } from "@/lib/adminModels"

function keySourceLabel(source: string): string {
  if (source === "env") return "Environment (env)"
  if (source === "file") return "Key file (file)"
  return source
}

export function KeyRotationCard({
  onAuthInvalid,
  refreshSignal = 0,
}: {
  onAuthInvalid: (msg: string) => void
  refreshSignal?: number
}) {
  const [status, setStatus] = useState<KeyStatusResponse | null>(null)
  const [loading, setLoading] = useState(true)
  const [rotating, setRotating] = useState(false)
  const [confirming, setConfirming] = useState(false)
  const [error, setError] = useState("")
  const [notice, setNotice] = useState("")
  const mountedRef = useRef(true)
  const triggerRef = useRef<HTMLButtonElement | null>(null)
  const cancelRef = useRef<HTMLButtonElement | null>(null)
  const shouldRestoreFocusRef = useRef(false)

  useEffect(() => {
    if (confirming) {
      shouldRestoreFocusRef.current = true
      cancelRef.current?.focus()
    } else if (!rotating && shouldRestoreFocusRef.current) {
      shouldRestoreFocusRef.current = false
      triggerRef.current?.focus()
    }
  }, [confirming, rotating])

  const loadStatus = useCallback(async () => {
    setLoading(true)
    setError("")
    try {
      const next = await getModelKeyStatus()
      if (mountedRef.current) setStatus(next)
    } catch (err) {
      if (!mountedRef.current) return
      if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) {
        onAuthInvalid(err.message)
        return
      }
      setError(err instanceof Error ? err.message : "Could not load key rotation status.")
    } finally {
      if (mountedRef.current) setLoading(false)
    }
  }, [onAuthInvalid])

  useEffect(() => {
    mountedRef.current = true
    void loadStatus()
    return () => {
      mountedRef.current = false
    }
  }, [loadStatus, refreshSignal])

  async function handleRotate() {
    if (rotating) return
    setRotating(true)
    setError("")
    setNotice("")
    try {
      const result = await rotateModelKeys()
      if (!mountedRef.current) return
      setConfirming(false)
      const latest = await getModelKeyStatus().catch(() => null)
      if (!mountedRef.current) return
      if (latest) {
        setStatus(latest)
      } else {
        setStatus((prev) => {
          const total = result.total_with_keys || (result.rotated_count + result.already_current_count)
          return {
            active_key_id: result.active_key_id || prev?.active_key_id || "",
            key_source: prev?.key_source || "file",
            previous_keys_configured: prev?.previous_keys_configured ?? 0,
            total_with_keys: total,
            current_v2_count: result.current_v2_count || total,
            needs_rotation_count: 0,
          }
        })
      }
      const keyId = result.active_key_id || latest?.active_key_id || "current"
      setNotice(`Re-encrypted ${result.rotated_count} stored credential(s) under active key ${keyId}.`)
    } catch (err) {
      if (!mountedRef.current) return
      if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) {
        onAuthInvalid(err.message)
        return
      }
      setConfirming(false)
      setError(err instanceof Error ? err.message : "Key rotation failed.")
    } finally {
      if (mountedRef.current) setRotating(false)
    }
  }

  const needsRotation = status?.needs_rotation_count ?? 0

  return (
    <section className="panel stack" aria-label="Credential encryption and key rotation">
      <div className="spread">
        <div>
          <h3 className="admin-sim-heading">
            <KeyRound size={17} aria-hidden="true" />
            Credential encryption &amp; key rotation
          </h3>
          <p className="muted">
            Inspect the active master key envelope and atomically re-encrypt stored model credentials into v2 format.
          </p>
        </div>
        <div className="row">
          {status && (
            <Badge variant={needsRotation > 0 ? "warning" : "success"}>
              {needsRotation > 0 ? `${needsRotation} needs rotation` : "All keys current"}
            </Badge>
          )}
          <Button type="button" variant="outline" size="sm" disabled={loading || rotating} onClick={() => void loadStatus()}>
            <RefreshCw size={14} aria-hidden="true" />
            {loading ? "Checking..." : "Refresh key status"}
          </Button>
          <Button
            ref={triggerRef}
            type="button"
            variant={needsRotation > 0 ? "default" : "outline"}
            size="sm"
            disabled={loading || rotating || !status || confirming}
            onClick={() => { setError(""); setNotice(""); setConfirming(true) }}
          >
            <ShieldCheck size={14} aria-hidden="true" />
            Re-encrypt stored keys
          </Button>
        </div>
      </div>

      {confirming && status && (
        <div className="admin-confirm-bar" role="region" aria-label="Confirm key rotation">
          <span>
            Re-encrypt {status.needs_rotation_count} pending credential(s) (across {status.total_with_keys} total stored)
            with active key {status.active_key_id}?
          </span>
          <div className="row">
            <Button type="button" variant="destructive" size="sm" disabled={rotating} onClick={() => void handleRotate()}>
              {rotating ? "Re-encrypting..." : "Confirm re-encryption"}
            </Button>
            <Button
              ref={cancelRef}
              type="button"
              variant="outline"
              size="sm"
              disabled={rotating}
              onClick={() => setConfirming(false)}
            >
              Cancel
            </Button>
          </div>
        </div>
      )}

      {error && <p role="alert" className="error">{error}</p>}
      {notice && <p role="status" className="notice">{notice}</p>}

      {loading && !status ? (
        <p role="status" className="muted">Loading key encryption status...</p>
      ) : status ? (
        <div className="admin-summary-grid" aria-label="Model secret key metrics">
          <article className="panel admin-metric">
            <div className="admin-metric-label"><span>Active key ID</span></div>
            <strong data-testid="active-key-id">{status.active_key_id || "Unavailable"}</strong>
            <small className="admin-mono">Source: {keySourceLabel(status.key_source)}</small>
          </article>
          <article className="panel admin-metric">
            <div className="admin-metric-label"><span>Previous keys configured</span></div>
            <strong>{status.previous_keys_configured}</strong>
            <small>{status.previous_keys_configured > 0 ? "Fallback decryption enabled" : "No previous keys set"}</small>
          </article>
          <article className="panel admin-metric">
            <div className="admin-metric-label"><span>Current v2 count</span></div>
            <strong>{status.current_v2_count}</strong>
            <small>of {status.total_with_keys} stored model keys</small>
          </article>
          <article className={`panel admin-metric${needsRotation > 0 ? " attention" : ""}`}>
            <div className="admin-metric-label"><span>Needs rotation</span></div>
            <strong>{needsRotation}</strong>
            <small>{needsRotation > 0 ? "Legacy v1 or prior key ID" : "All stored keys use active v2"}</small>
          </article>
        </div>
      ) : null}
    </section>
  )
}
