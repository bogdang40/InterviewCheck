import { Hono } from "hono";
import type { AuthService } from "../../services/AuthService.js";
import type { ApiTokenService } from "../../services/ApiTokenService.js";
import type { SessionManagementService } from "../../services/SessionManagementService.js";
import { authenticate, type AuthEnv } from "../middleware/Authenticate.js";
import { rateLimitUser, type FixedWindowRateLimiter } from "../middleware/RateLimit.js";
import { parseJsonBody, parseParams } from "../RequestParsing.js";
import { createApiTokenSchema, uuidParamSchema } from "../Schemas.js";

export interface SecurityRouteDeps {
  auth: AuthService;
  sessionManagement: SessionManagementService;
  apiTokens: ApiTokenService;
  apiTokenLimiter: FixedWindowRateLimiter;
}

export class SecurityRoutes {
  static build(deps: SecurityRouteDeps): Hono<AuthEnv> {
    const router = new Hono<AuthEnv>();
    const requireSession = authenticate(deps.auth);

    router.get("/auth/sessions", requireSession, (c) =>
      c.json(deps.sessionManagement.listSessions(c.get("user"), c.get("session"))),
    );

    router.delete("/auth/sessions/:id", requireSession, (c) => {
      const { id } = parseParams(c, uuidParamSchema);
      return c.json(deps.sessionManagement.revokeOwnSession(c.get("user"), c.get("session"), id));
    });

    router.get("/auth/tokens", requireSession, (c) =>
      c.json(deps.apiTokens.listApiTokens(c.get("user"))),
    );

    router.post("/auth/tokens", requireSession, rateLimitUser(deps.apiTokenLimiter), async (c) => {
      const body = await parseJsonBody(c, createApiTokenSchema);
      return c.json(deps.apiTokens.createApiToken(c.get("user"), body), 201);
    });

    router.delete("/auth/tokens/:id", requireSession, (c) => {
      const { id } = parseParams(c, uuidParamSchema);
      return c.json(deps.apiTokens.revokeApiToken(c.get("user"), id));
    });

    return router;
  }
}
