import { Hono, type Context } from "hono";
import type { ZodTypeAny, z } from "zod";
import type { Database } from "../../db/Database.js";
import type { AdminService } from "../../services/AdminService.js";
import type { AuditChainVerifier } from "../../services/AuditChainVerifier.js";
import type { AuthService } from "../../services/AuthService.js";
import type { SecurityService } from "../../services/SecurityService.js";
import { HttpError } from "../HttpError.js";
import { authenticate, requireAdmin, type AuthEnv } from "../middleware/Authenticate.js";
import { rateLimit, type ClientAddressResolver, type FixedWindowRateLimiter } from "../middleware/RateLimit.js";
import { parseJsonBody, parseParams, parseQuery } from "../RequestParsing.js";
import {
  adminAuditQuerySchema,
  adminAuditVerifyQuerySchema,
  adminListQuerySchema,
  adminPatchSchema,
  adminRateLimitQuerySchema,
  adminRevokeSessionsSchema,
  uuidParamSchema,
} from "../Schemas.js";

export interface AdminRouteDeps {
  auth: AuthService;
  admin: AdminService;
  auditVerifier: AuditChainVerifier;
  security: SecurityService;
  database: Database;
  adminReadLimiter: FixedWindowRateLimiter;
  adminWriteLimiter: FixedWindowRateLimiter;
  clientAddress: ClientAddressResolver;
}

/** Absent leaves the grant untouched, null clears it, a timestamp sets it. */
function grantFrom(raw: string | null | undefined): Date | null | undefined {
  if (raw === undefined) return undefined;
  if (raw === null) return null;
  return new Date(raw);
}

async function parseOptionalJsonBody<Schema extends ZodTypeAny>(c: Context, schema: Schema): Promise<z.infer<Schema>> {
  const rawText = await c.req.text();
  if (!rawText.trim()) {
    const empty = schema.safeParse({});
    if (empty.success) return empty.data;
    throw new HttpError(400, "invalid_json", "Request body must be valid JSON.");
  }
  let raw: unknown;
  try {
    raw = JSON.parse(rawText);
  } catch {
    throw new HttpError(400, "invalid_json", "Request body must be valid JSON.");
  }
  const result = schema.safeParse(raw);
  if (!result.success) {
    const first = result.error.issues[0];
    const where = first?.path.length ? `${first.path.join(".")}: ` : "";
    throw new HttpError(400, "validation_failed", `${where}${first?.message ?? "Invalid request."}`);
  }
  return result.data;
}

export class AdminRoutes {
  static build(deps: AdminRouteDeps): Hono<AuthEnv> {
    const router = new Hono<AuthEnv>();
    const readGuard = rateLimit(deps.adminReadLimiter, deps.clientAddress);
    const writeGuard = rateLimit(deps.adminWriteLimiter, deps.clientAddress);
    router.use("/admin/*", authenticate(deps.auth), requireAdmin());

    router.get("/admin/stats", readGuard, (c) => c.json(deps.admin.stats()));

    router.get("/admin/users", readGuard, (c) => {
      const query = parseQuery(c, adminListQuerySchema);
      return c.json(deps.admin.listUsers({ query: query.q, limit: query.limit, cursor: query.cursor }));
    });

    router.get("/admin/users/:id", readGuard, (c) => {
      const { id } = parseParams(c, uuidParamSchema);
      return c.json(deps.admin.getUser(id));
    });

    router.patch("/admin/users/:id", writeGuard, async (c) => {
      const { id } = parseParams(c, uuidParamSchema);
      const body = await parseJsonBody(c, adminPatchSchema);
      return c.json(
        deps.admin.updateUser(c.get("user"), id, {
          role: body.role,
          disabled: body.disabled,
          complimentaryUntil: grantFrom(body.complimentaryUntil),
        }),
      );
    });

    router.post("/admin/users/:id/reset-totp", writeGuard, (c) => {
      const { id } = parseParams(c, uuidParamSchema);
      return c.json(deps.admin.resetTwoFactor(c.get("user"), id));
    });

    router.get("/admin/users/:id/sessions", readGuard, (c) => {
      const { id } = parseParams(c, uuidParamSchema);
      return c.json(deps.security.listUserSessions(id));
    });

    router.post("/admin/users/:id/revoke-sessions", writeGuard, async (c) => {
      const { id } = parseParams(c, uuidParamSchema);
      const body = await parseOptionalJsonBody(c, adminRevokeSessionsSchema);
      return c.json(deps.security.revokeUserSessions(c.get("user"), id, body.sessionId));
    });

    router.get("/admin/rate-limits", readGuard, (c) => c.json(deps.security.listRateLimits()));

    router.delete("/admin/rate-limits", writeGuard, async (c) => {
      const query = parseQuery(c, adminRateLimitQuerySchema);
      const body = await parseOptionalJsonBody(c, adminRateLimitQuerySchema);
      return c.json(
        deps.security.clearRateLimits(c.get("user"), {
          limiter: body.limiter ?? query.limiter,
          keyHash: body.keyHash ?? query.keyHash,
          key: body.key ?? query.key,
        }),
      );
    });

    router.get("/admin/audit", readGuard, (c) => {
      const query = parseQuery(c, adminAuditQuerySchema);
      return c.json(
        deps.admin.listAudit({
          q: query.q,
          action: query.action,
          actor: query.actor,
          since: query.since ? new Date(query.since) : undefined,
          until: query.until ? new Date(query.until) : undefined,
          beforeId: query.beforeId,
          limit: query.limit ?? 100,
        }),
      );
    });

    router.get("/admin/audit/verify", readGuard, async (c) => {
      const { full } = parseQuery(c, adminAuditVerifyQuerySchema);
      return c.json(await deps.auditVerifier.verify(full ? "full" : "incremental"), 200, { "Cache-Control": "no-store" });
    });

    router.get("/admin/compliance/summary", readGuard, (c) => {
      const count = (sql: string, ...p: Array<string | number>) => Number(deps.database.get<{ n: number }>(sql, ...p)?.n ?? 0);
      const hasTable = (t: string) => Boolean(deps.database.get("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", t));
      const lastVerification = deps.auditVerifier.lastResult();
      const sid = c.get("session")?.id;
      const nowMs = (sid ? deps.database.get<{ last_seen_at: number }>("SELECT last_seen_at FROM sessions WHERE id = ?", sid)?.last_seen_at : undefined) ?? Date.now();
      return c.json({
        schemaVersion: deps.database.userVersion(),
        usersTotal: count("SELECT COUNT(*) AS n FROM users"),
        adminsTotal: count("SELECT COUNT(*) AS n FROM users WHERE role = 'admin' AND disabled = 0"),
        disabledUsersTotal: count("SELECT COUNT(*) AS n FROM users WHERE disabled = 1"),
        totpEnabledUsersTotal: hasTable("user_totp") ? count("SELECT COUNT(*) AS n FROM user_totp WHERE enabled = 1") : 0,
        activeSessionsTotal: count("SELECT COUNT(*) AS n FROM sessions WHERE revoked_at IS NULL AND expires_at > ?", nowMs),
        activeApiTokensTotal: hasTable("api_tokens") ? count("SELECT COUNT(*) AS n FROM api_tokens WHERE revoked_at IS NULL AND (expires_at IS NULL OR expires_at > ?)", nowMs) : 0,
        // The last recorded verification; GET /admin/audit/verify runs a new one.
        auditChainOk: lastVerification?.ok ?? null,
        auditChainVerifiedAt: lastVerification?.verifiedAt ?? null,
      }, 200, { "Cache-Control": "no-store" });
    });

    return router;
  }
}
