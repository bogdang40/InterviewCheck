import { TotpDecryptionError, type OpenedTotpSecret, type TotpSecretCipher } from "../crypto/TotpSecretCipher.js";
import type { Database } from "../db/Database.js";
import type { AuthSession } from "../domain/Session.js";
import type { User } from "../domain/User.js";
import { HttpError } from "../http/HttpError.js";
import type { AuditLogRepository } from "../repositories/AuditLogRepository.js";
import type { SessionRepository } from "../repositories/SessionRepository.js";
import type { TotpRecord, TotpRepository } from "../repositories/TotpRepository.js";
import type { UserRepository } from "../repositories/UserRepository.js";
import { BackupCodeVerifier } from "./BackupCodeVerifier.js";
import type { PasswordHasher } from "./PasswordHasher.js";
import { TotpAlgorithm } from "./TotpAlgorithm.js";

export interface TotpStatusView { readonly enabled: boolean; readonly verifiedAt: string | null; readonly remainingBackupCodes: number }
export interface TotpSetupView { readonly secret: string; readonly otpauthUri: string; readonly issuer: "InterviewCheck" }
export interface TotpVerifyView { readonly enabled: true; readonly verifiedAt: string; readonly backupCodes: string[] }

const ISSUER = "InterviewCheck" as const;

export class TotpService {
  private readonly backupCodes: BackupCodeVerifier;

  constructor(
    private readonly database: Database, private readonly users: UserRepository, private readonly totp: TotpRepository,
    private readonly sessions: SessionRepository, private readonly audit: AuditLogRepository, private readonly hasher: PasswordHasher, private readonly cipher: TotpSecretCipher,
    private readonly clock: () => Date = () => new Date(),
  ) {
    this.backupCodes = new BackupCodeVerifier(totp);
  }

  status(user: User): TotpStatusView {
    const record = this.totp.findByUserId(user.id);
    if (!record || !record.enabled) return { enabled: false, verifiedAt: null, remainingBackupCodes: 0 };
    return { enabled: true, verifiedAt: record.verifiedAt?.toISOString() ?? null, remainingBackupCodes: this.totp.countUnusedBackupCodes(user.id) };
  }

  /** Requires the password so a stolen session alone cannot bind an attacker's authenticator to the account. */
  async setup(user: User, currentPassword: string): Promise<TotpSetupView> {
    await this.requirePassword(user, currentPassword);
    const now = this.clock();
    const secret = TotpAlgorithm.randomSecret();
    const secretEnc = this.cipher.encrypt(secret, user.id);
    this.database.transaction(() => {
      if (this.totp.findByUserId(user.id)?.enabled) throw new HttpError(409, "totp_already_enabled", "Two-factor authentication is already enabled.");
      this.totp.upsertPending(user.id, secretEnc, now);
    });
    const label = `${encodeURIComponent(ISSUER)}:${encodeURIComponent(user.email)}`;
    const otpauthUri = `otpauth://totp/${label}?secret=${secret}&issuer=${encodeURIComponent(ISSUER)}&algorithm=SHA1&digits=6&period=30`;
    return { secret, otpauthUri, issuer: ISSUER };
  }

  /** Enabling TOTP signs out every other session, so one opened before enrolment cannot outlive it. */
  verify(user: User, currentSession: AuthSession, code: string): TotpVerifyView {
    const now = this.clock();
    const { codes, hashes } = BackupCodeVerifier.createBatch();
    return this.database.transaction(() => {
      const record = this.totp.findByUserId(user.id);
      if (!record) throw new HttpError(400, "totp_not_setup", "Two-factor setup has not been started.");
      if (record.enabled) throw new HttpError(409, "totp_already_enabled", "Two-factor authentication is already enabled.");
      const opened = this.openSecret(record);
      const step = opened ? TotpAlgorithm.matchStep(opened.secret, code, now.getTime()) : null;
      if (step === null || (record.lastUsedStep !== null && step <= record.lastUsedStep)) {
        throw new HttpError(400, "invalid_totp_code", "Verification code is invalid or expired.");
      }
      if (!this.totp.enable(user.id, step, now)) {
        throw new HttpError(409, "totp_already_enabled", "Two-factor authentication is already enabled.");
      }
      this.reencryptIfStale(record, opened!);
      this.totp.replaceBackupCodes(user.id, hashes, now);
      const revokedSessions = this.sessions.revokeAllForUserExcept(user.id, currentSession.id, now);
      this.audit.record({ actorUserId: user.id, action: "auth.totp_enabled", targetUserId: user.id, details: { revokedSessions } }, now);
      return { enabled: true, verifiedAt: now.toISOString(), backupCodes: codes };
    });
  }

  async disable(user: User, currentPassword: string, code: string): Promise<{ enabled: false }> {
    await this.requirePassword(user, currentPassword);
    const now = this.clock();
    return this.database.transaction(() => {
      if (!this.totp.findByUserId(user.id)?.enabled) throw new HttpError(400, "totp_not_enabled", "Two-factor authentication is not enabled.");
      if (!this.verifyLoginFactor(user.id, code, now)) throw new HttpError(401, "invalid_totp_code", "Invalid two-factor authentication code.");
      this.totp.deleteForUser(user.id);
      this.audit.record({ actorUserId: user.id, action: "auth.totp_disabled", targetUserId: user.id }, now);
      return { enabled: false };
    });
  }

  regenerateBackupCodes(user: User, code: string): { backupCodes: string[] } {
    const now = this.clock();
    const { codes, hashes } = BackupCodeVerifier.createBatch();
    return this.database.transaction(() => {
      const record = this.totp.findByUserId(user.id);
      if (!record || !record.enabled) throw new HttpError(400, "totp_not_enabled", "Two-factor authentication is not enabled.");
      const opened = this.openSecret(record);
      const step = opened ? TotpAlgorithm.matchStep(opened.secret, code, now.getTime()) : null;
      if (step === null || (record.lastUsedStep !== null && step <= record.lastUsedStep) || !this.totp.consumeStep(user.id, step)) {
        throw new HttpError(401, "invalid_totp_code", "Invalid two-factor authentication code.");
      }
      this.reencryptIfStale(record, opened!);
      this.totp.replaceBackupCodes(user.id, hashes, now);
      this.audit.record({ actorUserId: user.id, action: "auth.totp_backup_regenerated", targetUserId: user.id }, now);
      return { backupCodes: codes };
    });
  }

  isEnabled(userId: string): boolean { return this.totp.findByUserId(userId)?.enabled ?? false; }

  /**
   * An undecryptable seed (lost or rotated key) is logged and treated as a
   * non matching TOTP code, so backup codes still work and the caller answers
   * with the normal invalid code response instead of a 500.
   */
  verifyLoginFactor(userId: string, code: string, now: Date): "totp" | "backup_code" | null {
    const record = this.totp.findByUserId(userId);
    if (!record || !record.enabled) return null;
    const opened = this.openSecret(record);
    const step = opened ? TotpAlgorithm.matchStep(opened.secret, code, now.getTime()) : null;
    if (opened && step !== null) {
      if (record.lastUsedStep !== null && step <= record.lastUsedStep) return null;
      if (!this.totp.consumeStep(userId, step)) return null;
      this.reencryptIfStale(record, opened);
      return "totp";
    }
    return this.backupCodes.redeem(userId, code, now) ? "backup_code" : null;
  }

  private async requirePassword(user: User, currentPassword: string): Promise<void> {
    const storedHash = this.users.passwordHash(user.id);
    if (!(await this.hasher.verify(currentPassword, storedHash ?? (await this.hasher.decoyHash())))) {
      throw new HttpError(401, "invalid_credentials", "Current password is incorrect.");
    }
  }

  private openSecret(record: TotpRecord): OpenedTotpSecret | null {
    try {
      return this.cipher.decrypt(record.secretEnc, record.userId);
    } catch (error) {
      if (!(error instanceof TotpDecryptionError)) throw error;
      console.error(`[server] TOTP seed could not be decrypted (${error.reason}); only backup codes can sign this account in`);
      return null;
    }
  }

  private reencryptIfStale(record: TotpRecord, opened: OpenedTotpSecret): void {
    if (opened.isCurrent) return;
    this.totp.replaceSecret(record.userId, record.secretEnc, this.cipher.encrypt(opened.secret, record.userId));
  }

  static generateTotpCode(secretBase32: string, nowMs: number, stepOffset = 0): string {
    return TotpAlgorithm.generateCode(secretBase32, nowMs, stepOffset);
  }

  static matchTotpStep(secretBase32: string, rawCode: string, nowMs: number): number | null {
    return TotpAlgorithm.matchStep(secretBase32, rawCode, nowMs);
  }

  static verifyTotpCode(secretBase32: string, rawCode: string, nowMs: number): boolean {
    return TotpAlgorithm.matchStep(secretBase32, rawCode, nowMs) !== null;
  }
}
