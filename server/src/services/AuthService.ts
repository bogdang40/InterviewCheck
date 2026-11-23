import { AccessPolicy, MILLISECONDS_PER_DAY } from "../config/AppConfig.js";
import type { Database } from "../db/Database.js";
import { AuthSessionRules, type AuthSession } from "../domain/Session.js";
import { EmailNormalizer, type User } from "../domain/User.js";
import { HttpError } from "../http/HttpError.js";
import type { ApiTokenRepository } from "../repositories/ApiTokenRepository.js";
import type { AuditLogRepository } from "../repositories/AuditLogRepository.js";
import type { SessionRepository } from "../repositories/SessionRepository.js";
import type { UserRepository } from "../repositories/UserRepository.js";
import type { AdminBootstrap } from "./AdminBootstrap.js";
import type { AccessSnapshot, EntitlementService } from "./EntitlementService.js";
import type { LoginThrottle } from "./LoginThrottle.js";
import type { PasswordHasher } from "./PasswordHasher.js";
import type { TokenService } from "./TokenService.js";
import type { TotpService } from "./TotpService.js";

export interface Credentials {
  email: string;
  password: string;
  deviceName?: string | undefined;
  adminSecret?: string | undefined;
  totpCode?: string | undefined;
}

const SQLITE_CONSTRAINT_UNIQUE = 2067;

export interface SignedInResponse extends AccessSnapshot {
  readonly token: string;
}

export interface AuthenticatedRequest {
  readonly user: User;
  readonly session: AuthSession;
}

export class AuthService {
  constructor(
    private readonly database: Database,
    private readonly users: UserRepository,
    private readonly sessions: SessionRepository,
    private readonly apiTokens: ApiTokenRepository,
    private readonly audit: AuditLogRepository,
    private readonly hasher: PasswordHasher,
    private readonly tokens: TokenService,
    private readonly entitlements: EntitlementService,
    private readonly bootstrap: AdminBootstrap,
    private readonly policy: AccessPolicy,
    private readonly totp: TotpService,
    private readonly throttle: LoginThrottle,
    private readonly clock: () => Date = () => new Date(),
  ) {}

  async signup(credentials: Credentials): Promise<SignedInResponse> {
    const email = EmailNormalizer.normalize(credentials.email);
    if (this.users.findByEmail(email)) {
      throw new HttpError(409, "email_taken", "An account with this email already exists.");
    }
    const now = this.clock();
    const trialEndsAt = this.policy.trialDays > 0 ? new Date(now.getTime() + this.policy.trialDays * MILLISECONDS_PER_DAY) : null;
    const passwordHash = await this.hasher.hash(credentials.password);
    return this.database.transaction(() => {
      let user: User;
      try {
        user = this.users.create(
          { email, passwordHash, role: this.bootstrap.roleForNewAccount(email, credentials.adminSecret), trialEndsAt }, now,
        );
      } catch (error) {
        if ((error as { errcode?: number }).errcode === SQLITE_CONSTRAINT_UNIQUE) {
          throw new HttpError(409, "email_taken", "An account with this email already exists.");
        }
        throw error;
      }
      this.audit.record({ actorUserId: user.id, action: "auth.signup", targetUserId: user.id, details: { role: user.role } }, now);
      return this.issueSession(user, credentials.deviceName ?? null, now);
    });
  }

  /**
   * The per account lockout is checked before any account lookup or hashing,
   * and failures are counted for unknown emails too, so neither the 429 nor
   * its timing tells an attacker whether the account exists.
   */
  async login(credentials: Credentials): Promise<SignedInResponse> {
    const email = EmailNormalizer.normalize(credentials.email);
    if (this.throttle.isLockedOut(email, this.clock())) throw AuthService.tooManyAttempts();
    const user = this.users.findByEmail(email);
    const storedHash = user ? this.users.passwordHash(user.id) : null;
    const verified = await this.hasher.verify(credentials.password, storedHash ?? (await this.hasher.decoyHash()));
    const now = this.clock();
    if (!user || !verified) {
      this.database.transaction(() => this.throttle.recordFailure(email, now));
      throw new HttpError(401, "invalid_credentials", "Email or password is incorrect.");
    }
    const outcome = this.database.transaction(() => {
      const current = this.users.findById(user.id);
      if (!current || current.disabled) throw new HttpError(403, "account_disabled", "This account has been disabled.");
      let twoFactorMethod: "totp" | "backup_code" | null = null;
      if (this.totp.isEnabled(current.id)) {
        // Re-checked here because other attempts may have landed while the password hash ran.
        if (this.throttle.isLockedOut(email, now)) throw AuthService.tooManyAttempts();
        const code = credentials.totpCode?.trim();
        if (!code) {
          throw new HttpError(401, "totp_required", "Two-factor authentication code is required.");
        }
        twoFactorMethod = this.totp.verifyLoginFactor(current.id, code, now);
        if (!twoFactorMethod) {
          this.throttle.recordFailure(email, now);
          return null;
        }
      }
      this.throttle.reset(email);
      const updated = this.users.update(current.id, { lastLoginAt: now }, now);
      this.audit.record(
        {
          actorUserId: current.id,
          action: "auth.login",
          targetUserId: current.id,
          ...(twoFactorMethod ? { details: { twoFactor: twoFactorMethod } } : {}),
        },
        now,
      );
      return this.issueSession(updated, credentials.deviceName ?? null, now);
    });
    if (!outcome) {
      throw new HttpError(401, "invalid_totp_code", "Invalid two-factor authentication code.");
    }
    return outcome;
  }

  private static tooManyAttempts(): HttpError {
    return new HttpError(429, "rate_limited", "Too many attempts. Try again in a minute.");
  }

  async authenticate(token: string): Promise<AuthenticatedRequest | null> {
    if (!this.tokens.looksValid(token)) return null;
    const session = this.sessions.findByTokenHash(this.tokens.hash(token));
    const now = this.clock();
    if (!session || !AuthSessionRules.isUsable(session, now)) return null;
    const user = this.users.findById(session.userId);
    if (!user || user.disabled) return null;

    const ttlMillis = this.policy.sessionTtlDays * MILLISECONDS_PER_DAY;
    if (AuthSessionRules.shouldExtend(session, ttlMillis, now)) {
      this.sessions.touch(session.id, now, new Date(now.getTime() + ttlMillis));
    } else {
      this.sessions.touch(session.id, now, session.expiresAt);
    }
    return { user, session };
  }

  async changePassword(request: AuthenticatedRequest, currentPassword: string, newPassword: string): Promise<SignedInResponse> {
    const storedHash = this.users.passwordHash(request.user.id);
    const verified = await this.hasher.verify(currentPassword, storedHash ?? (await this.hasher.decoyHash()));
    if (!verified) {
      throw new HttpError(401, "invalid_credentials", "Current password is incorrect.");
    }
    const passwordHash = await this.hasher.hash(newPassword);
    const now = this.clock();
    return this.database.transaction(() => {
      const current = this.users.findById(request.user.id);
      if (!current || current.disabled) throw new HttpError(403, "account_disabled", "This account has been disabled.");
      const updated = this.users.update(current.id, { passwordHash }, now);
      this.sessions.revokeAllForUser(current.id, now);
      const revokedApiTokens = this.apiTokens.revokeAllForUser(current.id, now);
      this.audit.record({ actorUserId: current.id, action: "auth.password_change", targetUserId: current.id, details: { revokedApiTokens } }, now);
      return this.issueSession(updated, request.session.deviceName, now);
    });
  }

  logout(request: AuthenticatedRequest): void {
    const now = this.clock();
    this.database.transaction(() => {
      this.sessions.revoke(request.session.id, now);
      this.audit.record({ actorUserId: request.user.id, action: "auth.logout", targetUserId: request.user.id }, now);
    });
  }

  private issueSession(user: User, deviceName: string | null, now: Date): SignedInResponse {
    const token = this.tokens.generate();
    const expiresAt = new Date(now.getTime() + this.policy.sessionTtlDays * MILLISECONDS_PER_DAY);
    this.sessions.create({ userId: user.id, tokenHash: this.tokens.hash(token), deviceName, expiresAt }, now);
    return { token, ...this.entitlements.snapshotFor(user) };
  }
}
