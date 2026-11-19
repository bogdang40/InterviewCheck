import type { NextConfig } from "next"
import { PHASE_DEVELOPMENT_SERVER } from "next/constants"

// macOS file watcher limits can leave Next dev waiting before its first route.
// Watchpack reads this value before starting its directory watchers.
if (process.platform === "darwin" && !process.env.WATCHPACK_POLLING) {
  process.env.WATCHPACK_POLLING = "1000"
}

const exporting = process.env.INTERVIEWCHECK_STATIC_EXPORT === "1"
const apiPort = Number(process.env.INTERVIEWCHECK_API_PORT || 8000)
if (!Number.isInteger(apiPort) || apiPort < 1 || apiPort > 65535) {
  throw new Error("INTERVIEWCHECK_API_PORT must be a port between 1 and 65535.")
}

const BASELINE_HEADERS = [
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "X-Frame-Options", value: "DENY" },
  { key: "Referrer-Policy", value: "no-referrer" },
  {
    key: "Permissions-Policy",
    value: "camera=(), geolocation=(), payment=(), usb=(), microphone=(self), display-capture=(self)",
  },
]

const BASELINE_CSP =
  "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; " +
  "img-src 'self' data: blob:; font-src 'self'; media-src 'self' blob:; " +
  "connect-src 'self' ws: wss:; object-src 'none'; base-uri 'self'; " +
  "form-action 'self'; frame-ancestors 'none'; report-uri /api/csp-report"

export default function config(phase: string): NextConfig {
  return {
    typescript: { tsconfigPath: exporting ? "tsconfig.export.json" : "tsconfig.server.json" },
    trailingSlash: true,
    skipTrailingSlashRedirect: true,
    devIndicators: false,
    ...(exporting
      ? { output: "export" as const }
      : {
          distDir: process.env.INTERVIEWCHECK_NEXT_DIST_DIR || ".next-server",
          experimental: { proxyTimeout: 190_000, proxyClientMaxBodySize: "25mb" as const },
          async headers() {
            const nonApi = "/((?!api(?:/|$)|v1(?:/|$)).*)"
            if (phase === PHASE_DEVELOPMENT_SERVER) {
              return [{ source: nonApi, headers: BASELINE_HEADERS }]
            }
            return [
              {
                source: nonApi,
                headers: [...BASELINE_HEADERS, { key: "Content-Security-Policy", value: BASELINE_CSP }],
              },
            ]
          },
          async rewrites() {
            return ["/api", "/v1"].map((prefix) => ({
              source: prefix + "/:path*",
              destination: "http://127.0.0.1:" + apiPort + prefix + "/:path*",
            }))
          },
        }),
  }
}
