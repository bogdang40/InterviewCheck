import type { NextConfig } from "next"

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

const config: NextConfig = {
  typescript: { tsconfigPath: exporting ? "tsconfig.export.json" : "tsconfig.server.json" },
  trailingSlash: true,
  skipTrailingSlashRedirect: true,
  devIndicators: false,
  ...(exporting ? { output: "export" as const } : {
    distDir: ".next-server",
    experimental: { proxyTimeout: 190_000, proxyClientMaxBodySize: "25mb" as const },
    async rewrites() {
      return ["/api", "/v1"].map(prefix => ({
        source: prefix + "/:path*",
        destination: "http://127.0.0.1:" + apiPort + prefix + "/:path*",
      }))
    },
  }),
}
export default config
