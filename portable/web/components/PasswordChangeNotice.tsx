"use client"

import { useSyncExternalStore } from "react"
import { Button } from "./ui/button"

let pending = false
const listeners = new Set<() => void>()
const subscribe = (listener: () => void) => {
  listeners.add(listener)
  return () => { listeners.delete(listener) }
}

export function setPasswordChangeUnconfirmed(value: boolean) {
  if (pending === value) return
  pending = value
  for (const listener of listeners) listener()
}

export function PasswordChangeNotice() {
  const visible = useSyncExternalStore(subscribe, () => pending, () => false)
  if (!visible) return null
  return <div className="notice stack">
    <p role="status">The last password change in this tab was not confirmed. Sign in to check access.</p>
    <Button type="button" size="sm" variant="ghost" onClick={() => setPasswordChangeUnconfirmed(false)}>Dismiss notice</Button>
  </div>
}
