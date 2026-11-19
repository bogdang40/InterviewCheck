import type { Database } from "../db/Database.js";

export class StripeEventRepository {
  constructor(private readonly db: Database) {}

  isApplied(eventId: string): boolean {
    const row = this.db.get<{ applied_at: number | null }>("SELECT applied_at FROM stripe_events WHERE id = ?", eventId);
    return row?.applied_at != null;
  }

  /** Commit effects and the receipt together. Null receipts from older releases are retryable. */
  apply(eventId: string, type: string, now: Date, writeEffects: () => void): boolean {
    return this.db.transaction(() => {
      if (this.isApplied(eventId)) return false;
      writeEffects();
      this.db.run(
        `INSERT INTO stripe_events (id, type, received_at, applied_at) VALUES (?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET applied_at = excluded.applied_at`,
        eventId, type, now.getTime(), now.getTime(),
      );
      return true;
    });
  }
}
