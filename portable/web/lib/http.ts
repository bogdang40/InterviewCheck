/** The one HTTP client for workspace requests: the required header, defensive JSON and one error type. */

export class ApiError extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly code?: string,
  ) {
    super(message)
  }
}

export type ApiErrorType = new (status: number, message: string, code?: string) => ApiError

export type HttpOptions = RequestInit & {
  /** Serialized as the JSON request body. */
  json?: unknown
  /** The error message for a failed reply; defaults to `errorMessage`. */
  describe?: (data: unknown, status: number) => string
  /** The ApiError subclass a failed reply throws. */
  errorType?: ApiErrorType
  /** Full control over the thrown error, for replies that carry meaning in their headers. */
  toError?: (response: Response, data: unknown) => Error
}

/** The parsed JSON body, or null when it is empty or not JSON (a gateway's HTML error page, say). */
export function readJson(response: Response): Promise<unknown> {
  return response.json().catch(() => null)
}

/** FastAPI's `detail` (text, or the first validation error with its field path), then `error.message`. */
export function errorMessage(data: unknown, status: number): string {
  if (data && typeof data === "object") {
    const obj = data as { detail?: unknown; error?: { message?: unknown } }
    if (typeof obj.detail === "string" && obj.detail.trim()) return obj.detail
    if (Array.isArray(obj.detail) && obj.detail.length > 0) {
      const first = obj.detail[0] as { msg?: unknown; loc?: unknown }
      if (typeof first?.msg === "string") {
        const loc = Array.isArray(first.loc) ? first.loc.slice(1).join(".") : ""
        return loc ? `${loc}: ${first.msg}` : first.msg
      }
    }
    if (obj.error && typeof obj.error.message === "string" && obj.error.message.trim()) return obj.error.message
  }
  return `Request failed (HTTP ${status}).`
}

/** The reply's `detail` text, or `fallback` when it has none. */
export function detailOr(data: unknown, fallback: string): string {
  const detail = data && typeof data === "object" ? (data as { detail?: unknown }).detail : undefined
  return typeof detail === "string" && detail ? detail : fallback
}

export function errorCode(data: unknown): string | undefined {
  const code = data && typeof data === "object" ? (data as { error?: { code?: unknown } }).error?.code : undefined
  return typeof code === "string" ? code : undefined
}

/** Send a request; a reply that is not OK is thrown as an error built from its body. */
export async function send(url: string, options: HttpOptions = {}): Promise<Response> {
  const { json, describe = errorMessage, errorType = ApiError, toError, ...init } = options
  const headers = new Headers(init.headers)
  headers.set("X-InterviewCheck", "1")
  if (json !== undefined) init.body = JSON.stringify(json)
  if (init.body != null && !headers.has("Content-Type")) headers.set("Content-Type", "application/json")
  const response = await fetch(url, { ...init, headers, cache: "no-store" })
  if (!response.ok) {
    const data = await readJson(response)
    throw toError ? toError(response, data) : new errorType(response.status, describe(data, response.status), errorCode(data))
  }
  return response
}

/** Send a request and return its JSON body (null when the body is not JSON). */
export async function request<T>(url: string, options?: HttpOptions): Promise<T> {
  return (await readJson(await send(url, options))) as T
}
