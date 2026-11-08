import { Hono } from "hono";
import type { AdminService } from "../../services/AdminService.js";
import type { AuthService } from "../../services/AuthService.js";
import { authenticate, requireAdmin, type AuthEnv } from "../middleware/Authenticate.js";
import { parseJsonBody, parseQuery } from "../RequestParsing.js";
import { adminListQuerySchema, adminPatchSchema } from "../Schemas.js";

export interface AdminRouteDeps {
  auth: AuthService;
  admin: AdminService;
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
    router.use("/admin/*", authenticate(deps.auth), requireAdmin());

    router.get("/admin/stats", (c) => c.json(deps.admin.stats()));

    router.get("/admin/users", (c) => {
      const query = parseQuery(c, adminListQuerySchema);
      return c.json(deps.admin.listUsers({ query: query.q, limit: query.limit, cursor: query.cursor }));
    });

    router.get("/admin/users/:id", (c) => c.json(deps.admin.getUser(c.req.param("id"))));

    router.patch("/admin/users/:id", async (c) => {
      const body = await parseJsonBody(c, adminPatchSchema);
      return c.json(
        deps.admin.updateUser(c.get("user"), c.req.param("id"), {
          role: body.role,
          disabled: body.disabled,
          complimentaryUntil: grantFrom(body.complimentaryUntil),
        }),
      );
    });

    router.get("/admin/audit", (c) => {
      const limit = Number(c.req.query("limit") ?? 100);
      return c.json({ entries: deps.admin.recentAudit(Number.isFinite(limit) ? limit : 100) });
    });

    return router;
  }
}
