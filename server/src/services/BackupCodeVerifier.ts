import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import type { TotpRepository } from "../repositories/TotpRepository.js";

const BACKUP_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const BATCH_SIZE = 8;

/** Issues and redeems single use backup codes (stored as SHA-256 digests). */
export class BackupCodeVerifier {
  constructor(private readonly totp: TotpRepository) {}

  static createBatch(): { codes: string[]; hashes: string[] } {
    const half = () => [...randomBytes(4)].map((b) => BACKUP_CHARS[b & 31]!).join("");
    const codes = Array.from({ length: BATCH_SIZE }, () => `${half()}-${half()}`);
    return { codes, hashes: codes.map((code) => createHash("sha256").update(code, "utf8").digest("hex")) };
  }

  /** Case and hyphen insensitive. Marks the code used and returns true only on the first redemption. */
  redeem(userId: string, code: string, now: Date): boolean {
    const clean = code.trim().toUpperCase().replace(/[^A-Z0-9]/g, "");
    if (clean.length !== 8) return false;
    const candidateDigest = createHash("sha256").update(`${clean.slice(0, 4)}-${clean.slice(4, 8)}`, "utf8").digest();
    let matchedId: string | null = null;
    for (const row of this.totp.listUnusedBackupCodes(userId)) {
      const rowDigest = Buffer.from(row.codeHash, "hex");
      if (rowDigest.length === candidateDigest.length && timingSafeEqual(rowDigest, candidateDigest)) matchedId = row.id;
    }
    return matchedId !== null && this.totp.markBackupCodeUsed(matchedId, userId, now);
  }
}
