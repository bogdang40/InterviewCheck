/** Validation for the ?next= return path used after signing in. */

// Browsers read a backslash as a slash and drop tabs and newlines inside URLs, so either can turn
// "/x" into "//evil.example". Reject them outright instead of trying to normalize.
const UNSAFE_CHARACTERS = /[\u0000-\u001f\u007f\\]/

/** A same-origin path, search and hash for `raw`, or null when it could leave `origin`. */
export function safeNextPath(raw: string | null | undefined, origin: string): string | null {
  if (!raw || !raw.startsWith("/") || raw.startsWith("//") || UNSAFE_CHARACTERS.test(raw)) return null
  try {
    const base = new URL(origin)
    const resolved = new URL(raw, base)
    if (resolved.origin !== base.origin) return null
    return resolved.pathname + resolved.search + resolved.hash
  } catch {
    return null
  }
}

/** The validated ?next= of the current page, or null. */
export function nextPathFromLocation(): string | null {
  if (typeof window === "undefined") return null
  const next = new URLSearchParams(window.location.search).get("next")
  return safeNextPath(next, window.location.origin)
}
