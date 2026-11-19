import { Hono } from "hono";
import type { Database } from "../../db/Database.js";
import type { AuthService } from "../../services/AuthService.js";
import type { SecurityService } from "../../services/SecurityService.js";
import { HttpError } from "../HttpError.js";
import { authenticate, requireAdmin, type AuthEnv } from "../middleware/Authenticate.js";
import { rateLimit, type FixedWindowRateLimiter } from "../middleware/RateLimit.js";

const PROMETHEUS_MEDIA_TYPE = "text/plain; version=0.0.4; charset=utf-8";

export interface MetricsRouteDeps {
  auth: AuthService;
  database: Database;
  security: SecurityService;
  adminReadLimiter: FixedWindowRateLimiter;
  trustProxy: boolean;
}

export interface AccessMetricsSnapshot {
  readonly users_total: number;
  readonly active_sessions_total: number;
  readonly active_api_tokens_total: number;
  readonly audit_log_total: number;
  readonly rate_limit_buckets_total: number;
  readonly rate_limit_buckets: Record<string, number>;
}

function countQuery(db: Database, sql: string, ...params: Array<string | number>): number {
  return Number(db.get<{ n: number }>(sql, ...params)?.n ?? 0);
}

function collectAccessMetrics(deps: MetricsRouteDeps, sessionId?: string): {
  snapshot: AccessMetricsSnapshot;
  bucketSeries: Array<{ source: string; limiter: string; count: number }>;
} {
  const clockRow = sessionId ? deps.database.get<{ last_seen_at: number }>("SELECT last_seen_at FROM sessions WHERE id = ?", sessionId) : undefined;
  const nowMs = clockRow?.last_seen_at ?? Date.now();
  const hasApiTokens = Boolean(deps.database.get<{ ok: number }>("SELECT 1 AS ok FROM sqlite_master WHERE type='table' AND name='api_tokens'"));
  const entries = deps.security.listRateLimits().entries;
  const grouped = new Map<string, { source: string; limiter: string; count: number }>();
  for (const entry of entries) {
    const key = `${entry.source}:${entry.limiter}`;
    const current = grouped.get(key);
    if (current) current.count += 1;
    else grouped.set(key, { source: entry.source, limiter: entry.limiter, count: 1 });
  }
  const bucketSeries = [...grouped.values()].sort((a, b) => `${a.source}:${a.limiter}`.localeCompare(`${b.source}:${b.limiter}`));
  const rateLimitBuckets: Record<string, number> = {};
  for (const item of bucketSeries) rateLimitBuckets[`${item.source}:${item.limiter}`] = item.count;

  return {
    snapshot: {
      users_total: countQuery(deps.database, "SELECT COUNT(*) AS n FROM users"),
      active_sessions_total: countQuery(deps.database, "SELECT COUNT(*) AS n FROM sessions WHERE revoked_at IS NULL AND expires_at > ?", nowMs),
      active_api_tokens_total: hasApiTokens
        ? countQuery(deps.database, "SELECT COUNT(*) AS n FROM api_tokens WHERE revoked_at IS NULL AND (expires_at IS NULL OR expires_at > ?)", nowMs)
        : 0,
      audit_log_total: countQuery(deps.database, "SELECT COUNT(*) AS n FROM audit_log"),
      rate_limit_buckets_total: entries.length,
      rate_limit_buckets: rateLimitBuckets,
    },
    bucketSeries,
  };
}

function renderPrometheus(s: AccessMetricsSnapshot, buckets: Array<{ source: string; limiter: string; count: number }>): string {
  const lines = [
    "# HELP ic_access_users_total Total registered accounts.",
    "# TYPE ic_access_users_total gauge",
    `ic_access_users_total ${s.users_total}`,
    "# HELP ic_access_active_sessions_total Active non-revoked, unexpired sessions.",
    "# TYPE ic_access_active_sessions_total gauge",
    `ic_access_active_sessions_total ${s.active_sessions_total}`,
    "# HELP ic_access_active_api_tokens_total Active non-revoked, unexpired API tokens.",
    "# TYPE ic_access_active_api_tokens_total gauge",
    `ic_access_active_api_tokens_total ${s.active_api_tokens_total}`,
    "# HELP ic_access_audit_log_total Total audit log entries.",
    "# TYPE ic_access_audit_log_total gauge",
    `ic_access_audit_log_total ${s.audit_log_total}`,
    "# HELP ic_access_rate_limit_buckets_total Active rate-limit buckets.",
    "# TYPE ic_access_rate_limit_buckets_total gauge",
    `ic_access_rate_limit_buckets_total ${s.rate_limit_buckets_total}`,
    "# HELP ic_access_rate_limit_buckets Active rate-limit buckets by source and limiter.",
    "# TYPE ic_access_rate_limit_buckets gauge",
    ...buckets.map((b) => `ic_access_rate_limit_buckets{source="${b.source}",limiter="${b.limiter}"} ${b.count}`),
  ];
  return `${lines.join("\n")}\n`;
}

export class MetricsRoutes {
  static build(deps: MetricsRouteDeps): Hono<AuthEnv> {
    const router = new Hono<AuthEnv>();
    const readGuard = rateLimit(deps.adminReadLimiter, deps.trustProxy);
    router.get("/", authenticate(deps.auth), requireAdmin(), readGuard, (c) => {
      const format = c.req.query("format") ?? "prometheus";
      if (format !== "json" && format !== "prometheus") {
        throw new HttpError(400, "validation_failed", "format must be 'json' or 'prometheus'.");
      }
      const { snapshot, bucketSeries } = collectAccessMetrics(deps, c.get("session")?.id);
      if (format === "json") return c.json(snapshot, 200, { "Cache-Control": "no-store" });
      return c.text(renderPrometheus(snapshot, bucketSeries), 200, { "Content-Type": PROMETHEUS_MEDIA_TYPE, "Cache-Control": "no-store" });
    });
    return router;
  }
}
