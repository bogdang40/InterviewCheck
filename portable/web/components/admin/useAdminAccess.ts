"use client"

import { useCallback, useEffect, useRef, useState } from "react"
import { type ProviderStatus } from "@/lib/integrations"
import { type AccountSnapshot } from "@/lib/useAccountStatus"

async function readJson<T>(response: Response): Promise<T | null> {
  return (await response.json().catch(() => null)) as T | null
}

/** Workspace status and the signed-in account that decide whether the admin console may open. */
export function useAdminAccess() {
  const [status, setStatus] = useState<ProviderStatus | null>(null)
  const [account, setAccount] = useState<AccountSnapshot | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState("")
  const recheckInFlight = useRef(false)

  /** "initial" shows the gate while it loads; "recheck" keeps the console mounted so open tabs keep their edits. */
  const bootstrap = useCallback(async (mode: "initial" | "recheck" = "initial") => {
    if (mode === "initial") {
      setLoading(true)
      setError("")
    }
    try {
      const res = await fetch("/api/integrations/status", { cache: "no-store" })
      const nextStatus = res.ok ? await readJson<ProviderStatus>(res) : null
      if (!nextStatus) throw new Error(`Could not check workspace status (HTTP ${res.status}).`)
      setStatus(nextStatus)
      if (!nextStatus.access || !nextStatus.signedIn) {
        setAccount(null)
        return
      }
      const acctRes = await fetch("/api/integrations/account", { cache: "no-store" })
      setAccount(acctRes.ok ? await readJson<AccountSnapshot>(acctRes) : null)
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not check account status.")
    } finally {
      setLoading(false)
    }
  }, [])

  // Several tabs can fail together on one expired session; only the first starts a recheck.
  const onAuthInvalid = useCallback(
    (msg: string) => {
      setError(msg)
      if (recheckInFlight.current) return
      recheckInFlight.current = true
      void bootstrap("recheck").finally(() => {
        recheckInFlight.current = false
      })
    },
    [bootstrap],
  )

  const retry = useCallback(() => void bootstrap("initial"), [bootstrap])

  useEffect(() => {
    void bootstrap()
  }, [bootstrap])

  return { status, setStatus, account, setAccount, loading, error, setError, onAuthInvalid, retry }
}
