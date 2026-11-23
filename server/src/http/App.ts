import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import { secureHeaders } from "hono/secure-headers";
import type { Container } from "../Container.js";
import { HttpError } from "./HttpError.js";
import type { AuthEnv } from "./middleware/Authenticate.js";
import { AdminRoutes } from "./routes/AdminRoutes.js";
import { AuthRoutes } from "./routes/AuthRoutes.js";
import { BILLING_RETURN_STYLE_HASH } from "./routes/BillingReturnPage.js";
import { BillingRoutes } from "./routes/BillingRoutes.js";
import { MetricsRoutes } from "./routes/MetricsRoutes.js";
import { SecurityRoutes } from "./routes/SecurityRoutes.js";
import { TotpRoutes } from "./routes/TotpRoutes.js";

export const API_VERSION = "v1";

export class AppFactory {
  static create(container: Container, options: { quiet?: boolean } = {}): Hono<AuthEnv> {
    const app = new Hono<AuthEnv>();
    if (!options.quiet) app.use(async (c, next) => {
      const start = Date.now();
      await next();
      console.log(`[server] ${c.req.method} ${c.res.status} ${Date.now() - start}ms`);
    });
    app.use(
      secureHeaders({
        xFrameOptions: "DENY",
        referrerPolicy: "no-referrer",
        permissionsPolicy: { camera: [], microphone: [], geolocation: [], payment: [], usb: [] },
      }),
    );
    app.use(async (c, next) => {
      c.header("Cache-Control", "no-store");
      await next();
      const csp =
        c.req.path === `/${API_VERSION}/billing/return`
          ? `default-src 'none'; style-src '${BILLING_RETURN_STYLE_HASH}'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`
          : "default-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'";
      c.header("Content-Security-Policy", csp);
      c.header("Referrer-Policy", "no-referrer");
    });
    app.use("*", async (c, next) => {
      if (c.req.method === "OPTIONS" && c.req.header("access-control-request-method") !== undefined) {
        throw new HttpError(403, "forbidden", "Cross-origin preflight requests are not permitted.");
      }
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
    api.use("*", async (c, next) => {
      if (!["GET", "HEAD", "OPTIONS"].includes(c.req.method) && c.req.path !== `/${API_VERSION}/billing/webhook`) {
        if ((c.req.header("origin") || c.req.header("cookie")) && c.req.header("x-interviewcheck") !== "1") {
          throw new HttpError(403, "forbidden", "Missing workspace request header.");
        }
      }
      await next();
    });
    api.route(
      "/",
      AuthRoutes.build({
        auth: container.auth,
        entitlements: container.entitlements,
        credentialLimiter: container.credentialLimiter,
        clientAddress: container.clientAddress,
      }),
    );
    api.route(
      "/",
      TotpRoutes.build({
        auth: container.auth,
        totp: container.totp,
        totpLimiter: container.totpLimiter,
      }),
    );
    api.route(
      "/",
      SecurityRoutes.build({
        auth: container.auth,
        security: container.security,
      }),
    );
    api.route(
      "/",
      BillingRoutes.build({
        auth: container.auth,
        billing: container.billing,
        webhook: container.billingWebhook,
        appUrlScheme: container.config.APP_URL_SCHEME,
        billingLimiter: container.billingLimiter,
        clientAddress: container.clientAddress,
      }),
    );
    api.route(
      "/",
      AdminRoutes.build({
        auth: container.auth,
        admin: container.admin,
        audit: container.audit,
        security: container.security,
        database: container.database,
        adminReadLimiter: container.adminReadLimiter,
        adminWriteLimiter: container.adminWriteLimiter,
        clientAddress: container.clientAddress,
      }),
    );
    api.route(
      "/admin/metrics",
      MetricsRoutes.build({
        auth: container.auth,
        database: container.database,
        security: container.security,
        adminReadLimiter: container.adminReadLimiter,
        clientAddress: container.clientAddress,
      }),
    );
    app.route(`/${API_VERSION}`, api);

    app.notFound((c) => c.json({ error: { code: "not_found", message: "No such route." } }, 404));
    app.onError((error, c) => {
      if (error instanceof HttpError) {
        if (error.code === "totp_required") {
          c.header("X-InterviewCheck-TOTP", "required");
        }
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
