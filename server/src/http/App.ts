import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import { secureHeaders } from "hono/secure-headers";
import type { Container } from "../Container.js";
import { HttpError } from "./HttpError.js";
import type { AuthEnv } from "./middleware/Authenticate.js";
import { AdminRoutes } from "./routes/AdminRoutes.js";
import { AuthRoutes } from "./routes/AuthRoutes.js";
import { BillingRoutes } from "./routes/BillingRoutes.js";

export const API_VERSION = "v1";

export class AppFactory {
  static create(container: Container, options: { quiet?: boolean } = {}): Hono<AuthEnv> {
    const app = new Hono<AuthEnv>();
    if (!options.quiet) app.use(async (c, next) => {
      const start = Date.now();
      await next();
      console.log(`[server] ${c.req.method} ${c.res.status} ${Date.now() - start}ms`);
    });
    app.use(secureHeaders());
    app.use(async (c, next) => {
      c.header("Cache-Control", "no-store");
      await next();
    });
    app.use(
      bodyLimit({
        maxSize: 256 * 1024,
        onError: (c) => c.json({ error: { code: "payload_too_large", message: "Request body too large." } }, 413),
      }),
    );

    app.get("/health", (c) => {
      container.checkDatabase();
      return c.json({ ok: true, version: API_VERSION, billingConfigured: container.billing.isConfigured, time: new Date().toISOString() });
    });

    const api = new Hono<AuthEnv>();
    api.route(
      "/",
      AuthRoutes.build({
        auth: container.auth,
        entitlements: container.entitlements,
        credentialLimiter: container.credentialLimiter,
        trustProxy: container.config.TRUST_PROXY,
      }),
    );
    api.route("/", BillingRoutes.build({ auth: container.auth, billing: container.billing,
      webhook: container.billingWebhook, appUrlScheme: container.config.APP_URL_SCHEME }));
    api.route("/", AdminRoutes.build({ auth: container.auth, admin: container.admin }));
    app.route(`/${API_VERSION}`, api);

    app.notFound((c) => c.json({ error: { code: "not_found", message: "No such route." } }, 404));
    app.onError((error, c) => {
      if (error instanceof HttpError) {
        return c.json(error.toBody(), error.status as 400);
      }
      const code = (error as { code?: unknown }).code;
      const safeCode = typeof code === "string" && /^[A-Z0-9_]{1,40}$/.test(code) ? ` (${code})` : "";
      console.error(`[server] ${c.req.method} failed with ${error.constructor.name}${safeCode}`);
      return c.json({ error: { code: "internal_error", message: "Something went wrong." } }, 500);
    });
    return app;
  }
}
