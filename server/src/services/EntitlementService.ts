import type { Entitlement } from "../domain/Entitlement.js";
import { EntitlementResolver } from "../domain/Entitlement.js";
import { SubscriptionPresenter, type PublicSubscription } from "../domain/Subscription.js";
import { UserPresenter, type PublicUser, type User } from "../domain/User.js";
import type { SubscriptionRepository } from "../repositories/SubscriptionRepository.js";

export interface AccessSnapshot {
  readonly user: PublicUser;
  readonly entitlement: Entitlement;
  readonly subscription: PublicSubscription | null;
  readonly serverTime: string;
}

/** Joins a user with their current subscription and resolves entitlement. */
export class EntitlementService {
  constructor(
    private readonly subscriptions: SubscriptionRepository,
    private readonly resolver: EntitlementResolver,
    private readonly clock: () => Date = () => new Date(),
  ) {}

  snapshotFor(user: User): AccessSnapshot {
    const now = this.clock();
    const subscription = this.subscriptions.currentForUser(user.id);
    return {
      user: UserPresenter.toPublic(user),
      entitlement: this.resolver.resolve(user, subscription, now),
      subscription: SubscriptionPresenter.toPublic(subscription),
      serverTime: now.toISOString(),
    };
  }
}
