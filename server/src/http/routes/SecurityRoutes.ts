import { Hono } from "hono";
import type { AuthService } from "../../services/AuthService.js";
import type { SecurityService } from "../../services/SecurityService.js";
import { authenticate, type AuthEnv } from "../middleware/Authenticate.js";
import { rateLimitUser, type FixedWindowRateLimiter } from "../middleware/RateLimit.js";
import { parseJsonBody, parseParams } from "../RequestParsing.js";
import { createApiTokenSchema, uuidParamSchema } from "../Schemas.js";

export interface SecurityRouteDeps {
  auth: AuthService;
  security: SecurityService;
  apiTokenLimiter: FixedWindowRateLimiter;
}

export class SecurityRoutes {
  static build(deps: SecurityRouteDeps): Hono<AuthEnv> {
    const router = new Hono<AuthEnv>();
    const requireSession = authenticate(deps.auth);

    router.get("/auth/sessions", requireSession, (c) =>
      c.json(deps.security.listSessions(c.get("user"), c.get("session"))),
    );

    router.delete("/auth/sessions/:id", requireSession, (c) => {
      const { id } = parseParams(c, uuidParamSchema);
      return c.json(deps.security.revokeOwnSession(c.get("user"), c.get("session"), id));
    });

    router.get("/auth/tokens", requireSession, (c) =>
      c.json(deps.security.listApiTokens(c.get("user"))),
    );

    router.post("/auth/tokens", requireSession, rateLimitUser(deps.apiTokenLimiter), async (c) => {
      const body = await parseJsonBody(c, createApiTokenSchema);
      return c.json(deps.security.createApiToken(c.get("user"), body), 201);
    });

    router.delete("/auth/tokens/:id", requireSession, (c) => {
      const { id } = parseParams(c, uuidParamSchema);
      return c.json(deps.security.revokeApiToken(c.get("user"), id));
    });

    return router;
  }
}
