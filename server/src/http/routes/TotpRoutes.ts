import { Hono } from "hono";
import type { AuthService } from "../../services/AuthService.js";
import type { TotpService } from "../../services/TotpService.js";
import { authenticate, type AuthEnv } from "../middleware/Authenticate.js";
import { rateLimitUser, type FixedWindowRateLimiter } from "../middleware/RateLimit.js";
import { parseJsonBody } from "../RequestParsing.js";
import { totpCodeSchema, totpDisableSchema, totpSetupSchema } from "../Schemas.js";

export interface TotpRouteDeps {
  auth: AuthService;
  totp: TotpService;
  totpLimiter: FixedWindowRateLimiter;
}

export class TotpRoutes {
  static build(deps: TotpRouteDeps): Hono<AuthEnv> {
    const router = new Hono<AuthEnv>();
    const requireSession = authenticate(deps.auth);
    const totpGuard = rateLimitUser(deps.totpLimiter);

    router.get("/auth/totp/status", requireSession, (c) =>
      c.json(deps.totp.status(c.get("user"))),
    );

    router.post("/auth/totp/setup", requireSession, totpGuard, async (c) => {
      const body = await parseJsonBody(c, totpSetupSchema);
      return c.json(await deps.totp.setup(c.get("user"), body.currentPassword));
    });

    router.post("/auth/totp/verify", requireSession, totpGuard, async (c) => {
      const body = await parseJsonBody(c, totpCodeSchema);
      return c.json(deps.totp.verify(c.get("user"), c.get("session"), body.code));
    });

    router.post("/auth/totp/disable", requireSession, totpGuard, async (c) => {
      const body = await parseJsonBody(c, totpDisableSchema);
      return c.json(await deps.totp.disable(c.get("user"), body.currentPassword, body.code));
    });

    router.post("/auth/totp/backup-codes/regenerate", requireSession, totpGuard, async (c) => {
      const body = await parseJsonBody(c, totpCodeSchema);
      return c.json(deps.totp.regenerateBackupCodes(c.get("user"), body.code));
    });

    return router;
  }
}
