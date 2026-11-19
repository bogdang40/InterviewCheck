"use client"

import { useRef, type KeyboardEvent as ReactKeyboardEvent } from "react"
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

export function AdminTabNav<T extends string>({
  tabs,
  activeTab,
  onSelect,
  ariaLabel = "Admin sections",
}: AdminTabNavProps<T>) {
  const tabRefs = useRef<Partial<Record<T, HTMLButtonElement | null>>>({})

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
    onSelect(nextTab)
    tabRefs.current[nextTab]?.focus()
    tabRefs.current[nextTab]?.scrollIntoView({ block: "nearest", inline: "nearest" })
  }

  return (
    <div className="admin-tabs" role="tablist" aria-label={ariaLabel}>
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
