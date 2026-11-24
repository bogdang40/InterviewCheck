/** A stored compatibility percentage can be zero even when its denominator is empty. */
export function rateValue(pct: number, total: number | undefined, empty = "No reviewed answers") {
  if (total === 0) return empty
  // Older tag responses omit the denominator. Their stored zero can also mean no reviews.
  if (!Number.isFinite(pct) || (total === undefined ? pct <= 0 : !Number.isInteger(total) || total < 0)) return "Unavailable"
  return `${pct.toFixed(1)}%`
}

export function rateCounts(count: number | undefined, total: number | undefined) {
  return typeof count === "number" && Number.isInteger(count) && typeof total === "number" &&
    Number.isInteger(total) && total > 0 && count >= 0 && count <= total ? `${count} of ${total}` : ""
}

export function countedRate(pct: number, count: number | undefined, total: number | undefined, empty?: string) {
  const value = rateValue(pct, total, empty)
  const fraction = rateCounts(count, total)
  return fraction ? `${value} (${fraction})` : value
}
