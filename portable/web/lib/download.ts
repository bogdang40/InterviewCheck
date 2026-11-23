/** Saving a server reply as a file, with one rule for the file name a server may suggest. */

const MAX_NAME_LENGTH = 120

function suggestedName(header: string | null): string {
  if (!header) return ""
  const extended = /filename\*\s*=\s*(?:utf-8''|[^']*''|)([^;]+)/i.exec(header)
  if (extended?.[1]) {
    const raw = extended[1].trim().replace(/^["']|["']$/g, "")
    try { return decodeURIComponent(raw) } catch { return raw }
  }
  const plain = /filename\s*=\s*"([^"]+)"|filename\s*=\s*([^;\s]+)/i.exec(header)
  return (plain?.[1] || plain?.[2] || "").trim()
}

/**
 * A safe local name from a Content-Disposition header: no folders, only letters, digits, dot, dash and
 * underscore, and always the extension of `fallbackName`, which is used when nothing usable remains.
 */
export function downloadFilename(header: string | null, fallbackName: string): string {
  const base = (suggestedName(header).split(/[\\/]/).pop() || "").trim()
  const cleaned = base.replace(/[^a-zA-Z0-9._-]/g, "-").replace(/-+/g, "-").replace(/^[.-]+|[.-]+$/g, "")
  if (!cleaned) return fallbackName
  const ext = /\.[a-z0-9]+$/i.exec(fallbackName)?.[0] ?? ""
  const named = !ext || cleaned.toLowerCase().endsWith(ext.toLowerCase()) ? cleaned : cleaned.replace(/\.[a-z0-9]+$/i, "") + ext
  return named.slice(0, MAX_NAME_LENGTH) || fallbackName
}

/** Hand a blob to the browser as a download named `filename`. */
export function saveBlob(blob: Blob, filename: string): void {
  const objectUrl = URL.createObjectURL(blob)
  try {
    const anchor = document.createElement("a")
    anchor.href = objectUrl
    anchor.download = filename
    anchor.style.display = "none"
    document.body.appendChild(anchor)
    anchor.click()
    anchor.remove()
  } finally {
    window.setTimeout(() => URL.revokeObjectURL(objectUrl), 1000)
  }
}

/** Save a successful reply as a file and return the name it was saved under. */
export async function downloadResponse(response: Response, fallbackName: string): Promise<string> {
  const filename = downloadFilename(response.headers.get("Content-Disposition"), fallbackName)
  saveBlob(await response.blob(), filename)
  return filename
}
