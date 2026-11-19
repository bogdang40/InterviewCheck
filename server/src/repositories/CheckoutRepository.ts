import { randomUUID } from "node:crypto";
import type { Database } from "../db/Database.js";
import { CHECKOUT_BLOCKING_STATUSES, type Plan } from "../domain/Subscription.js";
import { HttpError } from "../http/HttpError.js";

export interface CheckoutAttempt {
  plan: Plan;
  request_id: string;
  expires_at: number;
  return_base: string;
  url: string | null;
}

const BLOCKING_STATUS_LIST = CHECKOUT_BLOCKING_STATUSES.map(() => "?").join(", ");

export class CheckoutRepository {
  constructor(private readonly db: Database) {}

  reserve(userId: string, plan: Plan, returnBase: string, now: Date, replacePending?: string): CheckoutAttempt {
    return this.db.transaction(() => {
      const subscription = this.db.get(
        `SELECT 1 FROM subscriptions WHERE user_id = ? AND plan IN ('monthly', 'annual')
         AND status IN (${BLOCKING_STATUS_LIST}) LIMIT 1`, userId, ...CHECKOUT_BLOCKING_STATUSES,
      );
      if (subscription) throw new HttpError(409, "subscription_exists", "This account has a subscription. Use the billing portal.");

      const nowSeconds = Math.floor(now.getTime() / 1000);
      const current = this.db.get<CheckoutAttempt>("SELECT * FROM checkout_requests WHERE user_id = ?", userId);
      if (current && current.expires_at > nowSeconds && !(current.request_id === replacePending && current.url === null)) {
        if (current.plan !== plan) {
          throw new HttpError(409, "checkout_open", "A checkout is open for the other plan. Reopen that plan or wait for it to expire.");
        }
        return current;
      }

      const attempt = { plan, request_id: randomUUID(), expires_at: nowSeconds + 3600, return_base: returnBase, url: null };
      this.db.run(
        `INSERT INTO checkout_requests (user_id, plan, request_id, expires_at, return_base) VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(user_id) DO UPDATE SET plan=excluded.plan, request_id=excluded.request_id,
         expires_at=excluded.expires_at, return_base=excluded.return_base, url=NULL`,
        userId, plan, attempt.request_id, attempt.expires_at, returnBase,
      );
      return attempt;
    });
  }

  saveUrl(userId: string, requestId: string, url: string): boolean {
    const result = this.db.run(
      "UPDATE checkout_requests SET url = ? WHERE user_id = ? AND request_id = ? AND url IS NULL", url, userId, requestId,
    );
    return Number(result.changes) === 1;
  }

  complete(userId: string, requestId: string): void {
    this.db.run("DELETE FROM checkout_requests WHERE user_id = ? AND request_id = ?", userId, requestId);
  }
}
