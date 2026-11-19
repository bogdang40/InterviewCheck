import type { Plan, PlanCatalog } from "../domain/Subscription.js";
import type { User } from "../domain/User.js";
import { HttpError } from "../http/HttpError.js";
import type { AuditLogRepository } from "../repositories/AuditLogRepository.js";
import type { CheckoutAttempt, CheckoutRepository } from "../repositories/CheckoutRepository.js";
import type { UserRepository } from "../repositories/UserRepository.js";
import { CheckoutExpiryRejected, type StripeGateway } from "../stripe/StripeGateway.js";

export class BillingService {
  constructor(
    private readonly gateway: StripeGateway,
    private readonly catalog: PlanCatalog,
    private readonly users: UserRepository,
    private readonly checkouts: CheckoutRepository,
    private readonly audit: AuditLogRepository,
    private readonly returnBase: string,
    private readonly clock: () => Date,
  ) {}

  get isConfigured(): boolean {
    return this.gateway.isConfigured && this.catalog.isConfigured;
  }

  availablePlans(): Plan[] {
    return this.catalog.availablePlans();
  }

  async createCheckout(user: User, plan: Plan): Promise<{ url: string }> {
    this.requireConfigured();
    const priceId = this.catalog.priceId(plan);
    if (!priceId) throw new HttpError(400, "unknown_plan", `Plan '${plan}' is not available.`);
    const attempt = this.checkouts.reserve(user.id, plan, this.returnBase, this.clock());
    if (attempt.url) return { url: attempt.url };

    const existingCustomer = this.users.requireById(user.id).stripeCustomerId;
    if (existingCustomer) {
      if (await this.gateway.hasCheckoutBlockingSubscription(existingCustomer, this.catalog.priceIds())) {
        throw new HttpError(409, "subscription_exists", "This account has a subscription. Use the billing portal.");
      }
    }
    const customerId = existingCustomer ?? await this.ensureCustomer(user);
    try {
      return await this.openCheckout(user.id, customerId, priceId, attempt);
    } catch (error) {
      const now = this.clock();
      if (!(error instanceof CheckoutExpiryRejected) || attempt.expires_at - now.getTime() / 1000 > 1860) throw error;
      // Stripe validated the original idempotent request and found no saved session to return.
      const next = this.checkouts.reserve(user.id, plan, this.returnBase, now, attempt.request_id);
      return next.url ? { url: next.url } : this.openCheckout(user.id, customerId, priceId, next);
    }
  }

  private async openCheckout(userId: string, customerId: string, priceId: string, attempt: CheckoutAttempt): Promise<{ url: string }> {
    const session = await this.gateway.createCheckoutSession({
      customerId,
      priceId,
      userId,
      requestId: attempt.request_id,
      expiresAt: attempt.expires_at,
      successUrl: `${attempt.return_base}?status=success`,
      cancelUrl: `${attempt.return_base}?status=cancel`,
    });
    if (this.checkouts.saveUrl(userId, attempt.request_id, session.url)) {
      this.audit.record({ actorUserId: userId, action: "billing.checkout_started", targetUserId: userId,
        details: { plan: attempt.plan, sessionId: session.id } }, this.clock());
    }
    return { url: session.url };
  }

  async createPortal(user: User): Promise<{ url: string }> {
    this.requireConfigured();
    const customerId = await this.ensureCustomer(user);
    return this.gateway.createPortalSession(customerId, `${this.returnBase}?status=portal`);
  }

  private async ensureCustomer(user: User): Promise<string> {
    const existing = this.users.requireById(user.id).stripeCustomerId;
    if (existing) return existing;
    const customerId = await this.gateway.createCustomer(user.email, user.id);
    return this.users.bindStripeCustomer(user.id, customerId, this.clock());
  }

  private requireConfigured(): void {
    if (!this.isConfigured) {
      throw new HttpError(503, "billing_not_configured", "Billing is not configured on this server.");
    }
  }
}
