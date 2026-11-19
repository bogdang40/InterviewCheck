"use client"

import { useCallback, useEffect, useState } from "react"
import type { ProviderStatus } from "./integrations"

export type AccountSnapshot = {
  email: string
  active: boolean
  admin?: boolean
}

export type AccountState = {
  status: ProviderStatus | null
  account: AccountSnapshot | null
  isAdmin: boolean
  loading: boolean
  refresh: () => void
}

export const ACCOUNT_EVENT = "interviewcheck:account"

export function notifyAccountChanged() {
  if (typeof window !== "undefined") {
    window.dispatchEvent(new Event(ACCOUNT_EVENT))
  }
}

export function useAccountStatus(trigger?: string): AccountState {
  const [status, setStatus] = useState<ProviderStatus | null>(null)
  const [account, setAccount] = useState<AccountSnapshot | null>(null)
  const [loading, setLoading] = useState(true)
  const [tick, setTick] = useState(0)

  const refresh = useCallback(() => {
    setTick((n) => n + 1)
  }, [])

  useEffect(() => {
    function onAccountEvent() {
      setTick((n) => n + 1)
    }
    window.addEventListener(ACCOUNT_EVENT, onAccountEvent)
    return () => window.removeEventListener(ACCOUNT_EVENT, onAccountEvent)
  }, [])

  useEffect(() => {
    const controller = new AbortController()
    setLoading(true)
    fetch("/api/integrations/status", { cache: "no-store", signal: controller.signal })
      .then((res) => (res.ok ? res.json() : null))
      .then(async (nextStatus: ProviderStatus | null) => {
        if (controller.signal.aborted) return
        setStatus(nextStatus)
        if (!nextStatus?.signedIn) {
          setAccount(null)
          setLoading(false)
          return
        }
        const acctRes = await fetch("/api/integrations/account", {
          cache: "no-store",
          signal: controller.signal,
        })
        if (controller.signal.aborted) return
        if (!acctRes.ok) {
          setAccount(null)
          setLoading(false)
          return
        }
        const nextAccount = (await acctRes.json()) as AccountSnapshot
        if (!controller.signal.aborted) {
          setAccount(nextAccount)
          setLoading(false)
        }
      })
      .catch(() => {
        if (!controller.signal.aborted) {
          setLoading(false)
        }
      })
    return () => controller.abort()
  }, [trigger, tick])

  return {
    status,
    account,
    isAdmin: Boolean(account?.admin),
    loading,
    refresh,
  }
}
