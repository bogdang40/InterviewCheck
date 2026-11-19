import { Database, dateFromSql, sqlBool, sqlDate } from "../db/Database.js";
import type { Plan, Subscription, SubscriptionStatus } from "../domain/Subscription.js";

interface SubscriptionRow {
  id: string;
  user_id: string;
  stripe_customer_id: string | null;
  status: SubscriptionStatus;
  price_id: string | null;
  plan: Plan | null;
  current_period_end: number | null;
  cancel_at_period_end: number;
  status_changed_at: number | null;
  created_at: number;
  updated_at: number;
}

export interface UpsertSubscriptionInput {
  id: string;
  userId: string;
  stripeCustomerId?: string;
  status: SubscriptionStatus;
  priceId: string | null;
  plan: Plan | null;
  currentPeriodEnd: Date | null;
  cancelAtPeriodEnd: boolean;
}

const COLUMNS = "id, user_id, stripe_customer_id, status, price_id, plan, current_period_end, cancel_at_period_end, status_changed_at, created_at, updated_at";

/** Statuses that count as "the customer currently has a live subscription". */
const LIVE_STATUSES: readonly SubscriptionStatus[] = ["active", "trialing", "past_due"];
const LIVE_STATUS_LIST = LIVE_STATUSES.map(() => "?").join(", ");
const LIVE_SUBSCRIPTION = `plan IN ('monthly', 'annual') AND status IN (${LIVE_STATUS_LIST})`;

export class SubscriptionRepository {
  constructor(private readonly db: Database) {}

  upsert(input: UpsertSubscriptionInput, now: Date = new Date()): Subscription {
    this.db.run(
      `INSERT INTO subscriptions (${COLUMNS}) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         user_id = excluded.user_id,
         stripe_customer_id = COALESCE(subscriptions.stripe_customer_id, excluded.stripe_customer_id),
         status = excluded.status,
         price_id = excluded.price_id,
         plan = excluded.plan,
         current_period_end = excluded.current_period_end,
         cancel_at_period_end = excluded.cancel_at_period_end,
         status_changed_at = CASE
           WHEN subscriptions.status = excluded.status THEN COALESCE(subscriptions.status_changed_at, excluded.status_changed_at)
           ELSE excluded.status_changed_at
         END,
         updated_at = excluded.updated_at`,
      input.id,
      input.userId,
      input.stripeCustomerId ?? null,
      input.status,
      input.priceId,
      input.plan,
      sqlDate(input.currentPeriodEnd),
      sqlBool(input.cancelAtPeriodEnd),
      now.getTime(),
      now.getTime(),
      now.getTime(),
    );
    const stored = this.findById(input.id);
    if (!stored) throw new Error("Subscription upsert did not persist");
    return stored;
  }

  findById(id: string): Subscription | null {
    const row = this.db.get<SubscriptionRow>(`SELECT ${COLUMNS} FROM subscriptions WHERE id = ?`, id);
    return row ? SubscriptionRepository.toSubscription(row) : null;
  }

  version(id: string): number {
    return this.db.get<{ version: number }>("SELECT version FROM subscription_versions WHERE id = ?", id)?.version ?? 0;
  }

  advanceVersion(id: string): void {
    this.db.run(
      `INSERT INTO subscription_versions (id, version) VALUES (?, 1)
       ON CONFLICT(id) DO UPDATE SET version = version + 1`,
      id,
    );
  }

  /**
   * The subscription that should drive entitlement: prefer a live one, then
   * fall back to the most recently updated record so a canceled plan is
   * still reported to the client.
   */
  currentForUser(userId: string, grantsAccess?: (subscription: Subscription) => boolean): Subscription | null {
    // Both candidates use the user/update index. Only the selected row is
    // materialized; equal timestamps keep the index's insertion order.
    const row = this.db.get<SubscriptionRow>(
      `SELECT ${COLUMNS} FROM subscriptions WHERE rowid = COALESCE(
         (SELECT rowid FROM subscriptions WHERE user_id = ? AND ${LIVE_SUBSCRIPTION}
          ORDER BY updated_at DESC, rowid ASC LIMIT 1),
         (SELECT rowid FROM subscriptions WHERE user_id = ?
          ORDER BY updated_at DESC, rowid ASC LIMIT 1)
       )`,
      userId,
      ...LIVE_STATUSES,
      userId,
    );
    if (!row) return null;
    const current = SubscriptionRepository.toSubscription(row);
    if (!grantsAccess || !row.plan || !LIVE_STATUSES.includes(row.status) || grantsAccess(current)) return current;
    const alternatives = this.db.all<SubscriptionRow>(
      `SELECT ${COLUMNS} FROM subscriptions WHERE user_id = ? AND ${LIVE_SUBSCRIPTION} AND id <> ?
       ORDER BY updated_at DESC, rowid ASC`,
      userId, ...LIVE_STATUSES, row.id,
    );
    for (const alternative of alternatives) {
      const subscription = SubscriptionRepository.toSubscription(alternative);
      if (grantsAccess(subscription)) return subscription;
    }
    return current;
  }

  countLive(): number {
    const row = this.db.get<{ n: number }>(
      `SELECT COUNT(DISTINCT user_id) AS n FROM subscriptions WHERE ${LIVE_SUBSCRIPTION}`,
      ...LIVE_STATUSES,
    );
    return Number(row?.n ?? 0);
  }

  private static toSubscription(row: SubscriptionRow): Subscription {
    return {
      id: row.id,
      userId: row.user_id,
      stripeCustomerId: row.stripe_customer_id,
      status: row.status,
      priceId: row.price_id,
      plan: row.plan,
      currentPeriodEnd: dateFromSql(row.current_period_end),
      cancelAtPeriodEnd: row.cancel_at_period_end === 1,
      statusChangedAt: dateFromSql(row.status_changed_at) ?? new Date(Number(row.updated_at)),
      createdAt: new Date(Number(row.created_at)),
      updatedAt: new Date(Number(row.updated_at)),
    };
  }
}
