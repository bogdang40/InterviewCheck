"use client"

import { type ReactNode } from "react"

/**
 * A tab panel that mounts the first time its tab opens and then stays mounted while hidden,
 * so each tab still loads its data on first open but a half finished edit survives a tab switch.
 */
export function AdminTabPanel({
  id,
  active,
  opened,
  className,
  children,
}: {
  id: string
  active: boolean
  opened: boolean
  className?: string
  children: ReactNode
}) {
  if (!opened) return null
  return (
    <div id={`panel-${id}`} role="tabpanel" aria-labelledby={`tab-${id}`} hidden={!active} className={className}>
      {children}
    </div>
  )
}
