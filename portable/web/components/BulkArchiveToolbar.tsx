"use client"

import { useEffect, useState } from "react"
import { ArchiveRestore, CheckSquare, Download, Tag, Trash2, X } from "lucide-react"
import { parseTagList, type BulkExportFormat } from "@/lib/bulkArchive"
import { Button } from "./ui/button"
import { Input } from "./ui/input"
import styles from "./BulkArchiveToolbar.module.css"

type Props = {
  mode: "archive" | "restore"
  selectedCount: number
  visibleCount: number
  allVisibleSelected: boolean
  busy?: boolean
  onSelectAll: () => void
  onClear: () => void
  onBulkTag?: (add: string[], remove: string[]) => Promise<void>
  onBulkExport?: (format: BulkExportFormat) => Promise<void>
  onBulkArchive?: (confirmCount: number) => Promise<void>
  onBulkRestore?: () => Promise<void>
}

export default function BulkArchiveToolbar({
  mode,
  selectedCount,
  visibleCount,
  allVisibleSelected,
  busy = false,
  onSelectAll,
  onClear,
  onBulkTag,
  onBulkExport,
  onBulkArchive,
  onBulkRestore,
}: Props) {
  const [tagText, setTagText] = useState("")
  const [confirming, setConfirming] = useState(false)
  const [confirmCountText, setConfirmCountText] = useState("")
  const [localError, setLocalError] = useState("")

  useEffect(() => {
    setConfirmCountText("")
    if (selectedCount === 0) {
      setConfirming(false)
      setLocalError("")
    }
  }, [selectedCount])

  if (visibleCount === 0 && selectedCount === 0) return null

  const noun = selectedCount === 1 ? "interview" : "interviews"
  const trimmedConfirm = confirmCountText.trim()
  const parsedConfirm = /^\d+$/.test(trimmedConfirm) ? Number.parseInt(trimmedConfirm, 10) : NaN
  const countMatches = selectedCount > 0 && parsedConfirm === selectedCount

  async function handleTag(kind: "add" | "remove") {
    if (!onBulkTag || busy || selectedCount === 0) return
    setLocalError("")
    try {
      const tags = parseTagList(tagText)
      if (!tags.length) {
        setLocalError("Enter at least one tag separated by commas.")
        return
      }
      await onBulkTag(kind === "add" ? tags : [], kind === "remove" ? tags : [])
      setTagText("")
    } catch (e) {
      setLocalError(e instanceof Error ? e.message : "Failed to update tags.")
    }
  }

  async function handleConfirm() {
    if (busy || !countMatches) return
    setLocalError("")
    try {
      if (mode === "archive" && onBulkArchive) await onBulkArchive(parsedConfirm)
      else if (mode === "restore" && onBulkRestore) await onBulkRestore()
      setConfirming(false)
      setConfirmCountText("")
    } catch (e) {
      setLocalError(e instanceof Error ? e.message : "Bulk operation failed.")
    }
  }

  const startConfirm = () => {
    setConfirming(true)
    setConfirmCountText("")
    setLocalError("")
  }

  return (
    <div
      className={selectedCount > 0 ? `${styles.toolbar} ${styles.toolbarActive}` : styles.toolbar}
      role="region"
      aria-label="Bulk selection actions"
    >
      <div className={styles.topRow}>
        <div className={styles.selectionInfo}>
          <span className={styles.countBadge} role="status" aria-live="polite">
            {selectedCount} selected
          </span>
          <Button type="button" variant="outline" size="sm" disabled={busy || visibleCount === 0 || allVisibleSelected} onClick={onSelectAll}>
            <CheckSquare />Select all ({visibleCount})
          </Button>
          {selectedCount > 0 && (
            <Button type="button" variant="ghost" size="sm" disabled={busy} onClick={onClear}>
              <X />Clear selection
            </Button>
          )}
        </div>

        {selectedCount > 0 && mode === "archive" && (
          <div className={styles.actions}>
            <div className={styles.tagGroup}>
              <Input
                className={styles.tagInput}
                type="text"
                maxLength={320}
                placeholder="Tags (comma-separated)"
                aria-label="Bulk tags"
                value={tagText}
                disabled={busy}
                onChange={(e) => { setTagText(e.target.value); if (localError) setLocalError("") }}
              />
              <Button type="button" variant="outline" size="sm" disabled={busy || !tagText.trim()} onClick={() => void handleTag("add")}>
                <Tag />Add tags
              </Button>
              <Button type="button" variant="outline" size="sm" disabled={busy || !tagText.trim()} onClick={() => void handleTag("remove")}>
                Remove tags
              </Button>
            </div>
            <Button type="button" variant="outline" size="sm" disabled={busy} onClick={() => void onBulkExport?.("csv")}>
              <Download />Export CSV
            </Button>
            <Button type="button" variant="outline" size="sm" disabled={busy} onClick={() => void onBulkExport?.("json")}>
              <Download />Export JSON
            </Button>
            <Button type="button" variant="destructive" size="sm" disabled={busy} onClick={startConfirm}>
              <Trash2 />Archive selected
            </Button>
          </div>
        )}

        {selectedCount > 0 && mode === "restore" && (
          <div className={styles.actions}>
            <Button type="button" variant="default" size="sm" disabled={busy} onClick={startConfirm}>
              <ArchiveRestore />Restore selected
            </Button>
          </div>
        )}
      </div>

      {confirming && selectedCount > 0 && (
        <div className={styles.confirmBox}>
          <span>
            {mode === "archive"
              ? `Enter ${selectedCount} to move ${selectedCount} ${noun} to Trash.`
              : `Enter ${selectedCount} to restore ${selectedCount} ${noun} from Trash.`}
          </span>
          <div className={styles.confirmControls}>
            <Input
              className={styles.confirmInput}
              type="number"
              inputMode="numeric"
              min={1}
              max={100}
              aria-label="Confirm selection count"
              placeholder={String(selectedCount)}
              value={confirmCountText}
              disabled={busy}
              onChange={(e) => { setConfirmCountText(e.target.value); if (localError) setLocalError("") }}
            />
            <Button
              type="button"
              variant={mode === "archive" ? "destructive" : "default"}
              size="sm"
              disabled={busy || !countMatches}
              onClick={() => void handleConfirm()}
            >
              {mode === "archive" ? `Confirm archive (${selectedCount})` : `Confirm restore (${selectedCount})`}
            </Button>
            <Button type="button" variant="ghost" size="sm" disabled={busy} onClick={() => { setConfirming(false); setConfirmCountText("") }}>
              Cancel
            </Button>
          </div>
        </div>
      )}

      {localError && <p className={styles.validationError} role="alert">{localError}</p>}
    </div>
  )
}
