import { Hono } from "hono";
import type { AuthService } from "../../services/AuthService.js";
import type { EntitlementService } from "../../services/EntitlementService.js";
import { authenticate, type AuthEnv } from "../middleware/Authenticate.js";
import { rateLimit, type FixedWindowRateLimiter } from "../middleware/RateLimit.js";
import { parseJsonBody } from "../RequestParsing.js";
import { credentialsSchema, passwordChangeSchema } from "../Schemas.js";

export interface AuthRouteDeps {
  auth: AuthService;
  entitlements: EntitlementService;
  credentialLimiter: FixedWindowRateLimiter;
  trustProxy: boolean;
}

export class AuthRoutes {
  static build(deps: AuthRouteDeps): Hono<AuthEnv> {
    const router = new Hono<AuthEnv>();
    const guard = rateLimit(deps.credentialLimiter, deps.trustProxy);

    router.post("/auth/signup", guard, async (c) => {
      const body = await parseJsonBody(c, credentialsSchema);
      return c.json(await deps.auth.signup(body), 201);
    });

    router.post("/auth/login", guard, async (c) => {
      const body = await parseJsonBody(c, credentialsSchema);
      return c.json(await deps.auth.login(body));
    });

    router.post("/auth/password", guard, authenticate(deps.auth), async (c) => {
      const body = await parseJsonBody(c, passwordChangeSchema);
      return c.json(await deps.auth.changePassword({ user: c.get("user"), session: c.get("session") }, body.currentPassword, body.newPassword));
    });

    router.post("/auth/logout", authenticate(deps.auth), (c) => {
      deps.auth.logout({ user: c.get("user"), session: c.get("session") });
      return c.body(null, 204);
    });

    router.get("/me", authenticate(deps.auth), (c) => c.json(deps.entitlements.snapshotFor(c.get("user"))));

    return router;
  }
}
