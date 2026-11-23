import type { ScorecardItem } from "./sessionScorecard"

export type ScoreConflict = { id: string; local?: ScorecardItem; saved?: ScorecardItem; removeLocal?: boolean }

function sameRow(a?: ScorecardItem, b?: ScorecardItem) {
  if (!a || !b) return a === b
  return a.criterion_id === b.criterion_id && a.criterion_label === b.criterion_label &&
    a.weight === b.weight && a.rating === b.rating && a.rationale === b.rationale
}

export function sameScores(a: ScorecardItem[], b: ScorecardItem[]) {
  return a.length === b.length && a.every((row, index) => sameRow(row, b[index]))
}

const indexRows = (rows: ScorecardItem[]) => new Map(rows.map((row) => [row.criterion_id, row]))

export function undoScoreRemoval(original: ScorecardItem, local: ScorecardItem, saved: ScorecardItem) {
  if (sameRow(original, saved)) return { row: local }
  if (sameRow(local, original) || sameRow(local, saved)) return { row: saved }
  return { row: local, conflict: { id: local.criterion_id, local, saved } }
}

export function reconcileScores(baseline: ScorecardItem[], draft: ScorecardItem[], current: ScorecardItem[], removals: ReadonlyMap<string, ScorecardItem>) {
  const old = indexRows(baseline), local = indexRows(draft), saved = indexRows(current)
  const rows: ScorecardItem[] = []
  const conflicts: ScoreConflict[] = []
  const pendingRemovals = new Map<string, ScorecardItem>()
  for (const id of new Set([...saved.keys(), ...local.keys()])) {
    const before = old.get(id), mine = local.get(id), theirs = saved.get(id)
    const markedAgainst = removals.get(id)
    if (mine && markedAgainst) {
      if (!theirs || theirs.rating === null) {
        // Another reviewer already cleared this score. A template can still supply an unrated row.
        if (theirs) rows.push(theirs)
      } else {
        rows.push(mine)
        pendingRemovals.set(id, markedAgainst)
        if (!sameRow(theirs, before)) conflicts.push({ id, local: mine, saved: theirs, removeLocal: true })
      }
      continue
    }
    const edited = !sameRow(mine, before)
    const picked = edited ? mine : theirs
    if (picked) rows.push(picked)
    if (edited && !sameRow(theirs, before) && !sameRow(mine, theirs)) conflicts.push({ id, local: mine, saved: theirs })
  }
  return { rows, conflicts, pendingRemovals }
}
