import { Hono, type Context } from "hono";
import type { ZodTypeAny, z } from "zod";
import type { AdminService } from "../../services/AdminService.js";
import type { AuthService } from "../../services/AuthService.js";
import type { SecurityService } from "../../services/SecurityService.js";
import { HttpError } from "../HttpError.js";
import { authenticate, requireAdmin, type AuthEnv } from "../middleware/Authenticate.js";
import { rateLimit, type FixedWindowRateLimiter } from "../middleware/RateLimit.js";
import { parseJsonBody, parseParams, parseQuery } from "../RequestParsing.js";
import {
  adminAuditQuerySchema,
  adminListQuerySchema,
  adminPatchSchema,
  adminRateLimitQuerySchema,
  adminRevokeSessionsSchema,
  uuidParamSchema,
} from "../Schemas.js";

export interface AdminRouteDeps {
  auth: AuthService;
  admin: AdminService;
  security: SecurityService;
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

    return router;
  }
}
