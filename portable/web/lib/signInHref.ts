const SIGN_IN_PATH = "/account/"

/**
 * Browser only: the sign-in link that returns to the current page afterwards.
 * The sign-in screen validates the path on the way back (lib/safeNextPath.ts).
 */
export function signInHrefForCurrentPage(): string {
  const here = window.location.pathname + window.location.search
  return here.startsWith(SIGN_IN_PATH) ? SIGN_IN_PATH : `${SIGN_IN_PATH}?next=${encodeURIComponent(here)}`
}
