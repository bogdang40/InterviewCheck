import { Database, dateFromSql, sqlBool, sqlDate } from "../db/Database.js";
import type { Plan, Subscription, SubscriptionStatus } from "../domain/Subscription.js";

interface SubscriptionRow {
  id: string;
  user_id: string;
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
  status: SubscriptionStatus;
  priceId: string | null;
  plan: Plan | null;
  currentPeriodEnd: Date | null;
  cancelAtPeriodEnd: boolean;
}

const COLUMNS = "id, user_id, status, price_id, plan, current_period_end, cancel_at_period_end, status_changed_at, created_at, updated_at";

/** Statuses that count as "the customer currently has a live subscription". */
const LIVE_STATUSES: readonly SubscriptionStatus[] = ["active", "trialing", "past_due"];
const LIVE_STATUS_PREDICATE = LIVE_STATUSES.map(() => "status = ?").join(" OR ");

export class SubscriptionRepository {
  constructor(private readonly db: Database) {}

  upsert(input: UpsertSubscriptionInput, now: Date = new Date()): Subscription {
    this.db.run(
      `INSERT INTO subscriptions (${COLUMNS}) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         user_id = excluded.user_id,
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

  /**
   * The subscription that should drive entitlement: prefer a live one, then
   * fall back to the most recently updated record so a canceled plan is
   * still reported to the client.
   */
  currentForUser(userId: string): Subscription | null {
    // Both candidates use the user/update index. Only the selected row is
    // materialized; equal timestamps keep the index's insertion order.
    const row = this.db.get<SubscriptionRow>(
      `SELECT ${COLUMNS} FROM subscriptions WHERE rowid = COALESCE(
         (SELECT rowid FROM subscriptions WHERE user_id = ? AND (${LIVE_STATUS_PREDICATE})
          ORDER BY updated_at DESC, rowid ASC LIMIT 1),
         (SELECT rowid FROM subscriptions WHERE user_id = ?
          ORDER BY updated_at DESC, rowid ASC LIMIT 1)
       )`,
      userId,
      ...LIVE_STATUSES,
      userId,
    );
    return row ? SubscriptionRepository.toSubscription(row) : null;
  }

  countLive(): number {
    const row = this.db.get<{ n: number }>(
      `SELECT COUNT(DISTINCT user_id) AS n FROM subscriptions WHERE ${LIVE_STATUS_PREDICATE}`,
      ...LIVE_STATUSES,
    );
    return Number(row?.n ?? 0);
  }

  private static toSubscription(row: SubscriptionRow): Subscription {
    return {
      id: row.id,
      userId: row.user_id,
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
