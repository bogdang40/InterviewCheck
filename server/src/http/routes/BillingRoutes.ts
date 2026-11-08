import { Hono } from "hono";
import type { AuthService } from "../../services/AuthService.js";
import type { BillingService } from "../../services/BillingService.js";
import { authenticate, type AuthEnv } from "../middleware/Authenticate.js";
import { parseJsonBody } from "../RequestParsing.js";
import { checkoutSchema } from "../Schemas.js";
import { BillingReturnPage } from "./BillingReturnPage.js";

export interface BillingRouteDeps {
  auth: AuthService;
  billing: BillingService;
  appUrlScheme: string;
}

export class BillingRoutes {
  static build(deps: BillingRouteDeps): Hono<AuthEnv> {
    const router = new Hono<AuthEnv>();
    const page = new BillingReturnPage(deps.appUrlScheme);

    router.get("/billing/plans", (c) =>
      c.json({ configured: deps.billing.isConfigured, plans: deps.billing.availablePlans() }),
    );

    router.post("/billing/checkout", authenticate(deps.auth), async (c) => {
      const body = await parseJsonBody(c, checkoutSchema);
      return c.json(await deps.billing.createCheckout(c.get("user"), body.plan));
    });

    router.post("/billing/portal", authenticate(deps.auth), async (c) =>
      c.json(await deps.billing.createPortal(c.get("user"))),
    );

    // Stripe posts here. Raw body is required for signature verification.
    router.post("/billing/webhook", async (c) => {
      const rawBody = await c.req.text();
      const result = await deps.billing.handleWebhook(rawBody, c.req.header("stripe-signature") ?? null);
      return c.json({ received: true, ...result });
    });

    // Browser lands here after Checkout or the Billing Portal.
    router.get("/billing/return", (c) => {
      const status = c.req.query("status") ?? "success";
      return c.html(page.render(status));
    });

    return router;
  }
}
