import { createCipheriv, createDecipheriv, createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import type { Database } from "../db/Database.js";
import type { User } from "../domain/User.js";
import { HttpError } from "../http/HttpError.js";
import type { AuditLogRepository } from "../repositories/AuditLogRepository.js";
import type { TotpRepository } from "../repositories/TotpRepository.js";
import type { UserRepository } from "../repositories/UserRepository.js";
import type { PasswordHasher } from "./PasswordHasher.js";

export interface TotpStatusView { readonly enabled: boolean; readonly verifiedAt: string | null; readonly remainingBackupCodes: number }
export interface TotpSetupView { readonly secret: string; readonly otpauthUri: string; readonly issuer: "InterviewCheck" }
export interface TotpVerifyView { readonly enabled: true; readonly verifiedAt: string; readonly backupCodes: string[] }

const BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
const BACKUP_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const ISSUER = "InterviewCheck" as const;

export class TotpService {
  constructor(
    private readonly database: Database, private readonly users: UserRepository, private readonly totp: TotpRepository,
    private readonly audit: AuditLogRepository, private readonly hasher: PasswordHasher, private readonly encryptionKey: Buffer,
    private readonly clock: () => Date = () => new Date(),
  ) {
    if (encryptionKey.length !== 32) throw new Error("TOTP encryption key must be 32 bytes.");
  }

  status(user: User): TotpStatusView {
    const record = this.totp.findByUserId(user.id);
    if (!record || !record.enabled) return { enabled: false, verifiedAt: null, remainingBackupCodes: 0 };
    return { enabled: true, verifiedAt: record.verifiedAt?.toISOString() ?? null, remainingBackupCodes: this.totp.countUnusedBackupCodes(user.id) };
  }

  setup(user: User): TotpSetupView {
    const now = this.clock();
    const secret = TotpService.encodeBase32(randomBytes(20));
    const secretEnc = this.encryptSecret(secret, user.id);
    this.database.transaction(() => {
      if (this.totp.findByUserId(user.id)?.enabled) throw new HttpError(409, "totp_already_enabled", "Two-factor authentication is already enabled.");
      this.totp.upsertPending(user.id, secretEnc, now);
    });
    const label = `${encodeURIComponent(ISSUER)}:${encodeURIComponent(user.email)}`;
    const otpauthUri = `otpauth://totp/${label}?secret=${secret}&issuer=${encodeURIComponent(ISSUER)}&algorithm=SHA1&digits=6&period=30`;
    return { secret, otpauthUri, issuer: ISSUER };
  }

  verify(user: User, code: string): TotpVerifyView {
    const now = this.clock();
    const { codes, hashes } = TotpService.createBackupBatch();
    return this.database.transaction(() => {
      const record = this.totp.findByUserId(user.id);
      if (!record) throw new HttpError(400, "totp_not_setup", "Two-factor setup has not been started.");
      if (record.enabled) throw new HttpError(409, "totp_already_enabled", "Two-factor authentication is already enabled.");
      const step = TotpService.matchTotpStep(this.decryptSecret(record.secretEnc, user.id), code, now.getTime());
      if (step === null || (record.lastUsedStep !== null && step <= record.lastUsedStep)) {
        throw new HttpError(400, "invalid_totp_code", "Verification code is invalid or expired.");
      }
      if (!this.totp.enable(user.id, step, now)) {
        throw new HttpError(409, "totp_already_enabled", "Two-factor authentication is already enabled.");
      }
      this.totp.replaceBackupCodes(user.id, hashes, now);
      this.audit.record({ actorUserId: user.id, action: "auth.totp_enabled", targetUserId: user.id }, now);
      return { enabled: true, verifiedAt: now.toISOString(), backupCodes: codes };
    });
  }

  async disable(user: User, currentPassword: string, code: string): Promise<{ enabled: false }> {
    const storedHash = this.users.passwordHash(user.id);
    if (!(await this.hasher.verify(currentPassword, storedHash ?? (await this.hasher.decoyHash())))) {
      throw new HttpError(401, "invalid_credentials", "Current password is incorrect.");
    }
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
    const { codes, hashes } = TotpService.createBackupBatch();
    return this.database.transaction(() => {
      const record = this.totp.findByUserId(user.id);
      if (!record || !record.enabled) throw new HttpError(400, "totp_not_enabled", "Two-factor authentication is not enabled.");
      const step = TotpService.matchTotpStep(this.decryptSecret(record.secretEnc, user.id), code, now.getTime());
      if (step === null || (record.lastUsedStep !== null && step <= record.lastUsedStep) || !this.totp.consumeStep(user.id, step)) {
        throw new HttpError(401, "invalid_totp_code", "Invalid two-factor authentication code.");
      }
      this.totp.replaceBackupCodes(user.id, hashes, now);
      this.audit.record({ actorUserId: user.id, action: "auth.totp_backup_regenerated", targetUserId: user.id }, now);
      return { backupCodes: codes };
    });
  }

  isEnabled(userId: string): boolean { return this.totp.findByUserId(userId)?.enabled ?? false; }

  verifyLoginFactor(userId: string, code: string, now: Date): "totp" | "backup_code" | null {
    const record = this.totp.findByUserId(userId);
    if (!record || !record.enabled) return null;
    const step = TotpService.matchTotpStep(this.decryptSecret(record.secretEnc, userId), code, now.getTime());
    if (step !== null) {
      if (record.lastUsedStep !== null && step <= record.lastUsedStep) return null;
      return this.totp.consumeStep(userId, step) ? "totp" : null;
    }
    const clean = code.trim().toUpperCase().replace(/[^A-Z0-9]/g, "");
    if (clean.length !== 8) return null;
    const candidateDigest = createHash("sha256").update(`${clean.slice(0, 4)}-${clean.slice(4, 8)}`, "utf8").digest();
    let matchedId: string | null = null;
    for (const row of this.totp.listUnusedBackupCodes(userId)) {
      const rowDigest = Buffer.from(row.codeHash, "hex");
      if (rowDigest.length === candidateDigest.length && timingSafeEqual(rowDigest, candidateDigest)) matchedId = row.id;
    }
    return matchedId && this.totp.markBackupCodeUsed(matchedId, userId, now) ? "backup_code" : null;
  }

  private encryptSecret(secretBase32: string, userId: string): string {
    const iv = randomBytes(12);
    const cipher = createCipheriv("aes-256-gcm", this.encryptionKey, iv).setAAD(Buffer.from(userId, "utf8"));
    const body = Buffer.concat([cipher.update(secretBase32, "utf8"), cipher.final()]);
    return `v1:${iv.toString("base64url")}:${cipher.getAuthTag().toString("base64url")}:${body.toString("base64url")}`;
  }

  private decryptSecret(secretEnc: string, userId: string): string {
    const parts = secretEnc.split(":");
    if (parts.length !== 4 || parts[0] !== "v1") throw new Error("Unsupported TOTP secret format.");
    const [iv, tag, body] = [Buffer.from(parts[1]!, "base64url"), Buffer.from(parts[2]!, "base64url"), Buffer.from(parts[3]!, "base64url")];
    if (iv.length !== 12 || tag.length !== 16 || body.length === 0) throw new Error("Malformed TOTP secret ciphertext.");
    const decipher = createDecipheriv("aes-256-gcm", this.encryptionKey, iv).setAAD(Buffer.from(userId, "utf8")).setAuthTag(tag);
    return Buffer.concat([decipher.update(body), decipher.final()]).toString("utf8");
  }

  static generateTotpCode(secretBase32: string, nowMs: number, stepOffset = 0): string {
    const key = TotpService.decodeBase32(secretBase32);
    const step = Math.floor(nowMs / 1000 / 30) + stepOffset;
    if (!Number.isSafeInteger(step) || step < 0) throw new RangeError("TOTP step must be a non-negative integer.");
    const msg = Buffer.alloc(8);
    msg.writeBigUInt64BE(BigInt(step));
    const digest = createHmac("sha1", key).update(msg).digest();
    const o = digest[digest.length - 1]! & 0x0f;
    const bin = ((digest[o]! & 0x7f) << 24) | ((digest[o + 1]! & 0xff) << 16) | ((digest[o + 2]! & 0xff) << 8) | (digest[o + 3]! & 0xff);
    return String(bin % 1_000_000).padStart(6, "0");
  }

  static matchTotpStep(secretBase32: string, rawCode: string, nowMs: number): number | null {
    const candidate = rawCode.trim();
    if (!/^\d{6}$/.test(candidate) || !Number.isFinite(nowMs)) return null;
    const baseStep = Math.floor(nowMs / 1000 / 30);
    const candidateBuf = Buffer.from(candidate, "utf8");
    let matchedStep: number | null = null;
    for (const offset of [-1, 0, 1]) {
      const step = baseStep + offset;
      if (step < 0) continue;
      if (timingSafeEqual(candidateBuf, Buffer.from(TotpService.generateTotpCode(secretBase32, nowMs, offset), "utf8"))) {
        matchedStep = step;
      }
    }
    return matchedStep;
  }

  static verifyTotpCode(secretBase32: string, rawCode: string, nowMs: number): boolean {
    return TotpService.matchTotpStep(secretBase32, rawCode, nowMs) !== null;
  }

  private static encodeBase32(bytes: Buffer): string {
    let bits = 0, value = 0, out = "";
    for (const byte of bytes) {
      value = (value << 8) | byte;
      bits += 8;
      while (bits >= 5) { out += BASE32[(value >>> (bits - 5)) & 31]!; bits -= 5; }
    }
    return bits > 0 ? out + BASE32[(value << (5 - bits)) & 31]! : out;
  }

  private static decodeBase32(encoded: string): Buffer {
    let bits = 0, value = 0;
    const out: number[] = [];
    for (const ch of encoded.trim().replace(/=+$/, "").toUpperCase()) {
      const idx = BASE32.indexOf(ch);
      if (idx === -1) throw new Error("Invalid Base32 secret.");
      value = (value << 5) | idx;
      bits += 5;
      if (bits >= 8) { out.push((value >>> (bits - 8)) & 0xff); bits -= 8; }
    }
    return Buffer.from(out);
  }

  private static createBackupBatch(): { codes: string[]; hashes: string[] } {
    const codes = Array.from({ length: 8 }, () => `${[...randomBytes(4)].map((b) => BACKUP_CHARS[b & 31]!).join("")}-${[...randomBytes(4)].map((b) => BACKUP_CHARS[b & 31]!).join("")}`);
    return { codes, hashes: codes.map((c) => createHash("sha256").update(c, "utf8").digest("hex")) };
  }
}
