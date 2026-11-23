/** A stored compatibility percentage can be zero even when its denominator is empty. */
export function rateValue(pct: number, total: number, empty = "No reviewed answers") {
  if (total === 0) return empty
  return total > 0 && Number.isFinite(pct) ? `${pct.toFixed(1)}%` : "Unavailable"
}

export function countedRate(pct: number, count: number, total: number, empty?: string) {
  const value = rateValue(pct, total, empty)
  return total > 0 && Number.isInteger(count) ? `${value} (${count} of ${total})` : value
}
