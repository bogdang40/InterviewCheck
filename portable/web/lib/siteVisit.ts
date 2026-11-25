import { send } from "./http"

export type PublicPage = "home" | "sample" | "signin"

const counted = new Set<PublicPage>()

/**
 * Counts one signed-out view of a public page for Admin > Usage. The server keeps no address:
 * only a hash with a salt it replaces every day. Never throws and never delays the page.
 */
export function recordVisit(page: PublicPage): void {
  if (counted.has(page)) return
  counted.add(page)
  void send("/api/usage/visit", { method: "POST", json: { page }, keepalive: true }).catch(() => undefined)
}
