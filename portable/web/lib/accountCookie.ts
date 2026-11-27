/** Order changes to the shared HttpOnly account cookie without reading or persisting it. */
const LOCK_NAME = "interviewcheck:account-cookie-write"
let localTail: Promise<void> = Promise.resolve()

function unsupported(error: unknown) {
  return error instanceof DOMException && (error.name === "SecurityError" || error.name === "NotSupportedError")
}

async function withOriginLock<T>(operation: () => Promise<T>): Promise<T> {
  let entered = false
  try {
    if (typeof navigator !== "undefined" && navigator.locks?.request) {
      return await navigator.locks.request(LOCK_NAME, () => {
        entered = true
        return operation()
      })
    }
  } catch (error) {
    // A rejected operation may already have changed the cookie. Never execute it again.
    if (entered || !unsupported(error)) throw error
  }
  return operation()
}

export function orderedAccountRequest<T>(send: () => Promise<T>): Promise<T> {
  const predecessor = localTail
  // Register with the browser immediately, including operations already queued by this document.
  const result = withOriginLock(() => predecessor.then(send))
  localTail = result.then(() => undefined, () => undefined)
  return result
}
