/** SQLite revision numbers may exceed the safe integer range in a browser. */
export function revisionNumber(numeric?: number, exact?: string): string {
  if (exact && /^[1-9][0-9]{0,18}$/.test(exact) && (exact.length < 19 || exact <= "9223372036854775807")) return exact
  if (numeric === undefined) return "1"
  return Number.isSafeInteger(numeric) && numeric > 0 ? String(numeric) : ""
}
