import { Hono } from "hono";
import type { AccessStatsQuery } from "../../repositories/AccessStatsQuery.js";
import type { AdminService } from "../../services/AdminService.js";
import type { AuditChainVerifier } from "../../services/AuditChainVerifier.js";
import type { AuthService } from "../../services/AuthService.js";
import type { RateLimitAdminService } from "../../services/RateLimitAdminService.js";
import type { SessionManagementService } from "../../services/SessionManagementService.js";
import { authenticate, requireAdmin, type AuthEnv } from "../middleware/Authenticate.js";
import { rateLimit, type ClientAddressResolver, type FixedWindowRateLimiter } from "../middleware/RateLimit.js";
import { parseJsonBody, parseOptionalJsonBody, parseParams, parseQuery } from "../RequestParsing.js";
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
  sessionManagement: SessionManagementService;
  rateLimitAdmin: RateLimitAdminService;
  stats: AccessStatsQuery;
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
      return c.json(deps.sessionManagement.listUserSessions(id));
    });

    router.post("/admin/users/:id/revoke-sessions", writeGuard, async (c) => {
      const { id } = parseParams(c, uuidParamSchema);
      const body = await parseOptionalJsonBody(c, adminRevokeSessionsSchema);
      return c.json(deps.sessionManagement.revokeUserSessions(c.get("user"), id, body.sessionId));
    });

    router.get("/admin/rate-limits", readGuard, (c) => c.json(deps.rateLimitAdmin.listRateLimits()));

    router.delete("/admin/rate-limits", writeGuard, async (c) => {
      const query = parseQuery(c, adminRateLimitQuerySchema);
      const body = await parseOptionalJsonBody(c, adminRateLimitQuerySchema);
      return c.json(
        deps.rateLimitAdmin.clearRateLimits(c.get("user"), {
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
      const nowMs = deps.stats.referenceTimeMs(c.get("session")?.id);
      const lastVerification = deps.auditVerifier.lastResult();
      return c.json({
        schemaVersion: deps.stats.schemaVersion(),
        usersTotal: deps.stats.usersTotal(),
        adminsTotal: deps.stats.activeAdminsTotal(),
        disabledUsersTotal: deps.stats.disabledUsersTotal(),
        totpEnabledUsersTotal: deps.stats.totpEnabledUsersTotal(),
        activeSessionsTotal: deps.stats.activeSessionsTotal(nowMs),
        activeApiTokensTotal: deps.stats.activeApiTokensTotal(nowMs),
        // The last recorded verification; GET /admin/audit/verify runs a new one.
        auditChainOk: lastVerification?.ok ?? null,
        auditChainVerifiedAt: lastVerification?.verifiedAt ?? null,
      }, 200, { "Cache-Control": "no-store" });
    });

    return router;
  }
}
