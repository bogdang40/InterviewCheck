import { Database } from "../db/Database.js";

/**
 * Idempotency ledger so a redelivered webhook never double applies.
 *
 * A claim is provisional until `markApplied` records that the event's
 * effects reached the database. If the process dies in between, the row
 * stays pending; once it is older than `pendingStaleAfterMs` the next
 * delivery of the same event id may claim it again.
 */
export class StripeEventRepository {
  static readonly pendingStaleAfterMs = 5 * 60 * 1000;

  constructor(private readonly db: Database) {}

  /** Returns true if this delivery should be applied. */
  claim(eventId: string, type: string, now: Date = new Date()): boolean {
    const inserted = this.db.run(
      "INSERT OR IGNORE INTO stripe_events (id, type, received_at, applied_at) VALUES (?, ?, ?, NULL)",
      eventId,
      type,
      now.getTime(),
    );
    if (Number(inserted.changes) === 1) return true;
    // Re-claim only a pending row that is stale; an applied row is a duplicate.
    const reclaimed = this.db.run(
      "UPDATE stripe_events SET received_at = ? WHERE id = ? AND applied_at IS NULL AND received_at <= ?",
      now.getTime(),
      eventId,
      now.getTime() - StripeEventRepository.pendingStaleAfterMs,
    );
    return Number(reclaimed.changes) === 1;
  }

  markApplied(eventId: string, now: Date = new Date()): void {
    this.db.run("UPDATE stripe_events SET applied_at = ? WHERE id = ?", now.getTime(), eventId);
  }

  release(eventId: string): void {
    this.db.run("DELETE FROM stripe_events WHERE id = ?", eventId);
  }

  isApplied(eventId: string): boolean {
    const row = this.db.get<{ applied_at: number | null }>("SELECT applied_at FROM stripe_events WHERE id = ?", eventId);
    return row?.applied_at != null;
  }
}
