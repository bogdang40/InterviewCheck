"use client"

import { useEffect, useRef, type KeyboardEvent as ReactKeyboardEvent } from "react"
import { type LucideIcon } from "lucide-react"

export type AdminTabItem<T extends string = string> = {
  id: T
  label: string
  Icon: LucideIcon
}

type AdminTabNavProps<T extends string> = {
  tabs: readonly AdminTabItem<T>[]
  activeTab: T
  onSelect: (tab: T) => void
  ariaLabel?: string
}

function ensureTabVisible(strip: HTMLDivElement | null, tab: HTMLButtonElement | null): void {
  if (!strip || !tab || strip.scrollWidth <= strip.clientWidth) return
  const sRect = strip.getBoundingClientRect()
  const tRect = tab.getBoundingClientRect()
  const pad = 4
  const maxScroll = Math.max(0, strip.scrollWidth - strip.clientWidth)
  if (tRect.left < sRect.left + pad) {
    strip.scrollLeft = Math.max(0, strip.scrollLeft + (tRect.left - (sRect.left + pad)))
  } else if (tRect.right > sRect.right - pad) {
    strip.scrollLeft = Math.min(maxScroll, strip.scrollLeft + (tRect.right - (sRect.right - pad)))
  }
}

export function AdminTabNav<T extends string>({
  tabs,
  activeTab,
  onSelect,
  ariaLabel = "Admin sections",
}: AdminTabNavProps<T>) {
  const stripRef = useRef<HTMLDivElement | null>(null)
  const tabRefs = useRef<Partial<Record<T, HTMLButtonElement | null>>>({})

  useEffect(() => {
    ensureTabVisible(stripRef.current, tabRefs.current[activeTab] ?? null)
  }, [activeTab])

  function handleKeyDown(e: ReactKeyboardEvent<HTMLButtonElement>, current: T) {
    if (!tabs.length) return
    const idx = tabs.findIndex((item) => item.id === current)
    if (idx < 0) return
    let nextIdx = -1
    if (e.key === "ArrowRight") nextIdx = (idx + 1) % tabs.length
    else if (e.key === "ArrowLeft") nextIdx = (idx - 1 + tabs.length) % tabs.length
    else if (e.key === "Home") nextIdx = 0
    else if (e.key === "End") nextIdx = tabs.length - 1
    if (nextIdx < 0) return
    e.preventDefault()
    const nextTab = tabs[nextIdx].id
    const nextEl = tabRefs.current[nextTab] ?? null
    onSelect(nextTab)
    nextEl?.focus({ preventScroll: true })
    ensureTabVisible(stripRef.current, nextEl)
  }

  return (
    <div ref={stripRef} className="admin-tabs" role="tablist" aria-label={ariaLabel}>
      {tabs.map(({ id, label, Icon }) => {
        const selected = activeTab === id
        return (
          <button
            key={id}
            ref={(el) => {
              tabRefs.current[id] = el
            }}
            id={`tab-${id}`}
            type="button"
            role="tab"
            aria-selected={selected}
            aria-controls={`panel-${id}`}
            tabIndex={selected ? 0 : -1}
            className="admin-tab"
            onClick={() => onSelect(id)}
            onKeyDown={(e) => handleKeyDown(e, id)}
          >
            <Icon size={15} aria-hidden="true" />
            {label}
          </button>
        )
      })}
    </div>
  )
}
