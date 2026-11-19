import { Hono } from "hono";
import type { AdminService } from "../../services/AdminService.js";
import type { AuthService } from "../../services/AuthService.js";
import { authenticate, requireAdmin, type AuthEnv } from "../middleware/Authenticate.js";
import { rateLimit, type FixedWindowRateLimiter } from "../middleware/RateLimit.js";
import { parseJsonBody, parseParams, parseQuery } from "../RequestParsing.js";
import { adminAuditQuerySchema, adminListQuerySchema, adminPatchSchema, uuidParamSchema } from "../Schemas.js";

export interface AdminRouteDeps {
  auth: AuthService;
  admin: AdminService;
  adminReadLimiter: FixedWindowRateLimiter;
  adminWriteLimiter: FixedWindowRateLimiter;
  trustProxy: boolean;
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
    const readGuard = rateLimit(deps.adminReadLimiter, deps.trustProxy);
    const writeGuard = rateLimit(deps.adminWriteLimiter, deps.trustProxy);
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

    return router;
  }
}
