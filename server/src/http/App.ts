import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import { logger } from "hono/logger";
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
    if (!options.quiet) app.use(logger());
    app.use(secureHeaders());
    app.use(
      bodyLimit({
        maxSize: 256 * 1024,
        onError: (c) => c.json({ error: { code: "payload_too_large", message: "Request body too large." } }, 413),
      }),
    );

    app.get("/health", (c) =>
      c.json({ ok: true, version: API_VERSION, billingConfigured: container.billing.isConfigured, time: new Date().toISOString() }),
    );

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
    api.route("/", BillingRoutes.build({ auth: container.auth, billing: container.billing, appUrlScheme: container.config.APP_URL_SCHEME }));
    api.route("/", AdminRoutes.build({ auth: container.auth, admin: container.admin }));
    app.route(`/${API_VERSION}`, api);

    app.notFound((c) => c.json({ error: { code: "not_found", message: "No such route." } }, 404));
    app.onError((error, c) => {
      if (error instanceof HttpError) {
        return c.json(error.toBody(), error.status as 400);
      }
      console.error("[server] unhandled error", error);
      return c.json({ error: { code: "internal_error", message: "Something went wrong." } }, 500);
    });
    return app;
  }
}
