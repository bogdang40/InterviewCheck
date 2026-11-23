import { randomUUID } from "node:crypto";
import { Database, dateFromSql, sqlDate } from "../db/Database.js";

export interface TotpRecord {
  readonly userId: string;
  readonly secretEnc: string;
  readonly enabled: boolean;
  readonly verifiedAt: Date | null;
  readonly createdAt: Date;
  readonly lastUsedStep: number | null;
}

export interface BackupCodeRecord {
  readonly id: string;
  readonly userId: string;
  readonly codeHash: string;
  readonly usedAt: Date | null;
  readonly createdAt: Date;
}

interface TotpRow {
  user_id: string;
  secret_enc: string;
  enabled: number;
  verified_at: number | null;
  created_at: number;
  last_used_step: number | null;
}

interface BackupCodeRow {
  id: string;
  user_id: string;
  code_hash: string;
  used_at: number | null;
  created_at: number;
}

export class TotpRepository {
  constructor(private readonly db: Database) {}

  findByUserId(userId: string): TotpRecord | null {
    const row = this.db.get<TotpRow>(
      "SELECT user_id, secret_enc, enabled, verified_at, created_at, last_used_step FROM user_totp WHERE user_id = ?",
      userId,
    );
    return row ? TotpRepository.toTotpRecord(row) : null;
  }

  upsertPending(userId: string, secretEnc: string, now: Date): void {
    const ts = now.getTime();
    this.db.run(
      `INSERT INTO user_totp (user_id, secret_enc, enabled, verified_at, created_at, last_used_step)
       VALUES (?, ?, 0, NULL, ?, NULL)
       ON CONFLICT(user_id) DO UPDATE SET secret_enc = excluded.secret_enc, enabled = 0, verified_at = NULL, created_at = excluded.created_at, last_used_step = NULL`,
      userId,
      secretEnc,
      ts,
    );
  }

  enable(userId: string, step: number, now: Date): boolean {
    const result = this.db.run(
      "UPDATE user_totp SET enabled = 1, verified_at = ?, last_used_step = ? WHERE user_id = ? AND enabled = 0",
      now.getTime(),
      step,
      userId,
    );
    return Number(result.changes) === 1;
  }

  consumeStep(userId: string, step: number): boolean {
    const result = this.db.run(
      "UPDATE user_totp SET last_used_step = ? WHERE user_id = ? AND enabled = 1 AND (last_used_step IS NULL OR last_used_step < ?)",
      step,
      userId,
      step,
    );
    return Number(result.changes) === 1;
  }

  /** Replaces the stored ciphertext only if it is still the one the caller read, so a concurrent setup is not overwritten. */
  replaceSecret(userId: string, expectedSecretEnc: string, secretEnc: string): boolean {
    const result = this.db.run(
      "UPDATE user_totp SET secret_enc = ? WHERE user_id = ? AND secret_enc = ?",
      secretEnc,
      userId,
      expectedSecretEnc,
    );
    return Number(result.changes) === 1;
  }

  listSecrets(): Array<{ userId: string; secretEnc: string }> {
    return this.db
      .all<{ user_id: string; secret_enc: string }>("SELECT user_id, secret_enc FROM user_totp")
      .map((row) => ({ userId: row.user_id, secretEnc: row.secret_enc }));
  }

  /** Returns true when a TOTP record existed. */
  deleteForUser(userId: string): boolean {
    this.db.run("DELETE FROM user_backup_codes WHERE user_id = ?", userId);
    return Number(this.db.run("DELETE FROM user_totp WHERE user_id = ?", userId).changes) > 0;
  }

  countUnusedBackupCodes(userId: string): number {
    const row = this.db.get<{ n: number }>(
      "SELECT COUNT(*) AS n FROM user_backup_codes WHERE user_id = ? AND used_at IS NULL",
      userId,
    );
    return Number(row?.n ?? 0);
  }

  replaceBackupCodes(userId: string, codeHashes: readonly string[], now: Date): void {
    this.db.run("DELETE FROM user_backup_codes WHERE user_id = ?", userId);
    const ts = now.getTime();
    for (const codeHash of codeHashes) {
      this.db.run(
        "INSERT INTO user_backup_codes (id, user_id, code_hash, used_at, created_at) VALUES (?, ?, ?, NULL, ?)",
        randomUUID(),
        userId,
        codeHash,
        ts,
      );
    }
  }

  listUnusedBackupCodes(userId: string): BackupCodeRecord[] {
    const rows = this.db.all<BackupCodeRow>(
      "SELECT id, user_id, code_hash, used_at, created_at FROM user_backup_codes WHERE user_id = ? AND used_at IS NULL",
      userId,
    );
    return rows.map(TotpRepository.toBackupCodeRecord);
  }

  markBackupCodeUsed(id: string, userId: string, now: Date): boolean {
    const result = this.db.run(
      "UPDATE user_backup_codes SET used_at = ? WHERE id = ? AND user_id = ? AND used_at IS NULL",
      sqlDate(now),
      id,
      userId,
    );
    return Number(result.changes) === 1;
  }

  private static toTotpRecord(row: TotpRow): TotpRecord {
    return {
      userId: row.user_id,
      secretEnc: row.secret_enc,
      enabled: Number(row.enabled) === 1,
      verifiedAt: dateFromSql(row.verified_at),
      createdAt: new Date(Number(row.created_at)),
      lastUsedStep: row.last_used_step === null || row.last_used_step === undefined ? null : Number(row.last_used_step),
    };
  }

  private static toBackupCodeRecord(row: BackupCodeRow): BackupCodeRecord {
    return {
      id: row.id,
      userId: row.user_id,
      codeHash: row.code_hash,
      usedAt: dateFromSql(row.used_at),
      createdAt: new Date(Number(row.created_at)),
    };
  }
}
