import type { PlanCatalog } from "../domain/Subscription.js";
import { HttpError } from "../http/HttpError.js";
import type { AuditLogRepository } from "../repositories/AuditLogRepository.js";
import type { CheckoutRepository } from "../repositories/CheckoutRepository.js";
import type { StripeEventRepository } from "../repositories/StripeEventRepository.js";
import type { SubscriptionRepository } from "../repositories/SubscriptionRepository.js";
import type { UserRepository } from "../repositories/UserRepository.js";
import type { BillingEvent, StripeGateway } from "../stripe/StripeGateway.js";

export class BillingWebhookService {
  constructor(
    private readonly gateway: StripeGateway,
    private readonly catalog: PlanCatalog,
    private readonly users: UserRepository,
    private readonly subscriptions: SubscriptionRepository,
    private readonly checkouts: CheckoutRepository,
    private readonly events: StripeEventRepository,
    private readonly audit: AuditLogRepository,
    private readonly clock: () => Date,
  ) {}

  async receive(rawBody: string, signature: string | null): Promise<{ handled: boolean; type: string }> {
    return this.apply(await this.gateway.parseWebhook(rawBody, signature));
  }

  async apply(event: BillingEvent): Promise<{ handled: boolean; type: string }> {
    if (event.type === "ignored") return { handled: false, type: event.rawType };
    if (this.events.isApplied(event.id)) return { handled: false, type: event.type };

    const checkout = event.type === "checkout.completed" ? event : null;
    const eventSubscription = event.type === "checkout.completed" ? null : event.subscription;
    const id = checkout?.subscriptionId ?? eventSubscription?.id;
    const customerId = checkout?.customerId ?? eventSubscription?.customerId;
    if (!id || !customerId) throw new HttpError(422, "invalid_event", "Stripe event is missing its subscription or customer.");

    // Fetch provider state without holding SQLite's write lock. Verify the local version before committing it.
    const version = this.subscriptions.version(id);
    const subscription = event.type === "subscription.deleted" ? event.subscription : await this.gateway.retrieveSubscription(id);
    if (subscription.id !== id || subscription.customerId !== customerId) {
      throw new HttpError(422, "invalid_event", "Stripe subscription and event ownership disagree.");
    }

    const now = this.clock();
    let linked = true;
    const applied = this.events.apply(event.id, event.type, now, () => {
      if (this.subscriptions.version(id) !== version) {
        throw new HttpError(503, "subscription_changed", "Concurrent subscription change. Retry this event.");
      }
      const current = this.subscriptions.findById(id);
      const user = this.users.findByStripeCustomerId(customerId) ?? (current ? this.users.findById(current.userId) : null);
      const owner = subscription.metadataUserId ?? eventSubscription?.metadataUserId;
      // No account knows this customer or subscription. Retrying cannot change that, and a 4xx makes Stripe retry for
      // days and eventually disable the endpoint, so record the receipt and leave an audit trail for follow up.
      if (!user && !current) {
        linked = false;
        this.audit.record({ actorUserId: null, action: "billing.unlinked_customer",
          details: { eventId: event.id, type: event.type, customerId, subscriptionId: id, claimedUserId: owner ?? checkout?.clientReferenceId ?? null } }, now);
        return;
      }
      if (!user || (owner && owner !== user.id) || (checkout?.clientReferenceId && checkout.clientReferenceId !== user.id)
          || (current && current.userId !== user.id) || (current?.stripeCustomerId && current.stripeCustomerId !== customerId)) {
        throw new HttpError(422, "unknown_customer", "Unknown or inconsistent billing customer.");
      }
      const status = event.type === "subscription.deleted" ? "canceled" : subscription.status;
      if (current?.status !== "canceled" || status === "canceled") {
        const plan = this.catalog.planFor(subscription.priceId)
          ?? (current && current.priceId === subscription.priceId ? current.plan : null);
        this.subscriptions.upsert({
          id, userId: user.id, stripeCustomerId: customerId, status, priceId: subscription.priceId, plan,
          currentPeriodEnd: subscription.currentPeriodEnd, cancelAtPeriodEnd: subscription.cancelAtPeriodEnd,
        }, now);
        this.audit.record({ actorUserId: null, action: "billing.subscription_synced", targetUserId: user.id,
          details: { status, subscriptionId: id } }, now);
      }
      if (checkout) {
        if (checkout.checkoutRequestId) this.checkouts.complete(user.id, checkout.checkoutRequestId);
        this.audit.record({ actorUserId: null, action: "billing.checkout_completed", targetUserId: user.id }, now);
      }
      this.subscriptions.advanceVersion(id);
    });
    return { handled: applied && linked, type: event.type };
  }
}
