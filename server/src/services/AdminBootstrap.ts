import { timingSafeEqual } from "node:crypto";
import type { UserRole } from "../domain/User.js";

/**
 * Decides whether a brand new account may start as admin. Two things must
 * hold: the email is on the ADMIN_EMAILS allow list, and the signup carried
 * ADMIN_BOOTSTRAP_SECRET. The allow list alone is not enough because signup
 * has no email verification, so anyone could otherwise claim an admin
 * address first. Later role changes go through the admin API.
 */
export class AdminBootstrap {
  private readonly emails: ReadonlySet<string>;

  constructor(
    adminEmails: readonly string[],
    private readonly secret: string | undefined,
  ) {
    this.emails = new Set(adminEmails.map((email) => email.trim().toLowerCase()));
  }

  get isConfigured(): boolean {
    return this.emails.size > 0 && Boolean(this.secret);
  }

  roleForNewAccount(email: string, presentedSecret: string | undefined): UserRole {
    if (!this.emails.has(email) || !this.secret || !presentedSecret) return "user";
    const expected = Buffer.from(this.secret, "utf8");
    const presented = Buffer.from(presentedSecret, "utf8");
    return expected.length === presented.length && timingSafeEqual(expected, presented) ? "admin" : "user";
  }
}
