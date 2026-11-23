import type { Database } from "../db/Database.js";

export interface LoginThrottlePolicy {
  readonly windowMs: number;
  readonly maxFailures: number;
}

/** The single definition of the per account login window, shared by login and the admin rate limit view. */
export const LOGIN_THROTTLE_POLICY: LoginThrottlePolicy = Object.freeze({ windowMs: 15 * 60_000, maxFailures: 10 });

/**
 * Counts failed sign in attempts (wrong password or wrong second factor) per
 * normalized email in login_email_windows, independent of client address.
 * Emails without an account are counted the same way, so a lockout reveals
 * nothing about which accounts exist.
 */
export class LoginThrottle {
  constructor(
    private readonly database: Database,
    readonly policy: LoginThrottlePolicy = LOGIN_THROTTLE_POLICY,
  ) {}

  isLockedOut(email: string, now: Date): boolean {
    this.pruneExpired(now);
    const row = this.database.get<{ hits: number }>("SELECT hits FROM login_email_windows WHERE email = ?", email);
    return Number(row?.hits ?? 0) >= this.policy.maxFailures;
  }

  recordFailure(email: string, now: Date): void {
    this.pruneExpired(now);
    this.database.run(
      `INSERT INTO login_email_windows (email, start, hits) VALUES (?, ?, 1)
       ON CONFLICT(email) DO UPDATE SET hits = hits + 1`,
      email,
      now.getTime(),
    );
  }

  reset(email: string): void {
    this.database.run("DELETE FROM login_email_windows WHERE email = ?", email);
  }

  private pruneExpired(now: Date): void {
    this.database.run("DELETE FROM login_email_windows WHERE start <= ?", now.getTime() - this.policy.windowMs);
  }
}
