"use client"

import { useCallback, useEffect, useRef, useState } from "react"
import { readAccountSnapshot, type AccountSnapshot } from "./accountSnapshot"
import type { ProviderStatus } from "./integrations"

export type { AccountSnapshot } from "./accountSnapshot"

export type AccountState = {
  status: ProviderStatus | null
  account: AccountSnapshot | null
  isAdmin: boolean
  loading: boolean
  refresh: () => void
}

export const ACCOUNT_EVENT = "interviewcheck:account"

const ACCOUNT_CHANGE_KEY = "interviewcheck:account-generation"
const ROTATION_STARTED = "interviewcheck:password-rotation-started"
let documentMarker: string | undefined
function documentId() {
  // A routing label lives only in this document. It contains no account or session data.
  return documentMarker ??= (globalThis.crypto?.randomUUID?.() ?? Math.random().toString(36).slice(2))
}

export function cancelPreRotationStatusRead() {
  window.dispatchEvent(new Event(ROTATION_STARTED))
}

function accountChannel() {
  try { return typeof BroadcastChannel === "undefined" ? null : new BroadcastChannel(ACCOUNT_CHANGE_KEY) }
  catch { return null }
}

export function notifyAccountChanged(change: "identity" | "rotation" | "refresh" = "identity") {
  if (typeof window === "undefined") return
  // Rotation confirms the current operator locally. Other tabs must discard authority bound to the old cookie.
  window.dispatchEvent(new CustomEvent(ACCOUNT_EVENT, { detail: change === "identity" }))
  if (change === "refresh") return
  // Only an invalidation marker crosses tabs. No account ID or credential is stored.
  try {
    window.localStorage.setItem(ACCOUNT_CHANGE_KEY, crypto.randomUUID())
  } catch {
    const channel = accountChannel()
    if (channel) {
      channel.postMessage({ change: "identity", sender: documentId() })
      channel.close()
    }
  }
}

export function useAccountStatus(trigger?: string, enabled = true): AccountState {
  const [status, setStatus] = useState<ProviderStatus | null>(null)
  const [account, setAccount] = useState<AccountSnapshot | null>(null)
  const [loading, setLoading] = useState(enabled)
  const [tick, setTick] = useState(0)
  const pending = useRef<AbortController | null>(null)

  const refresh = useCallback(() => {
    setTick((n) => n + 1)
  }, [])

  useEffect(() => {
    if (!enabled) return
    function invalidate() {
      pending.current?.abort()
      setAccount(null)
      setStatus(null)
      setLoading(true)
      setTick(n => n + 1)
    }
    function onAccountEvent(event: Event) {
      if ((event as CustomEvent).detail === false) {
        pending.current?.abort()
        setTick(n => n + 1)
      } else invalidate()
    }
    function onStorage(event: StorageEvent) {
      if (event.key === ACCOUNT_CHANGE_KEY || event.key === null) invalidate()
    }
    const cancelPending = () => pending.current?.abort()
    const fallback = accountChannel()
    if (fallback) fallback.onmessage = event => {
      // A different BroadcastChannel object in this same document also receives the message.
      if (event.data === "changed" || (event.data?.change === "identity" && event.data.sender !== documentId())) invalidate()
    }
    window.addEventListener(ROTATION_STARTED, cancelPending)
    window.addEventListener(ACCOUNT_EVENT, onAccountEvent)
    window.addEventListener("storage", onStorage)
    return () => {
      window.removeEventListener(ROTATION_STARTED, cancelPending)
      window.removeEventListener(ACCOUNT_EVENT, onAccountEvent)
      window.removeEventListener("storage", onStorage)
      fallback?.close()
    }

  }, [enabled])

  useEffect(() => {
    if (!enabled) {
      setLoading(false)
      return
    }
    const controller = new AbortController()
    pending.current = controller
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
        const nextAccount = readAccountSnapshot(await acctRes.json())
        if (!controller.signal.aborted) {
          setAccount(nextAccount)
          setLoading(false)
        }
      })
      .catch(() => {
        if (!controller.signal.aborted) {
          setAccount(null)
          setStatus(null)
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
