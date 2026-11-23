import { randomUUID } from "node:crypto";
import { Database, dateFromSql } from "../db/Database.js";
import type { AuthSession } from "../domain/Session.js";

interface SessionRow {
  id: string;
  user_id: string;
  token_hash: string;
  device_name: string | null;
  created_at: number;
  expires_at: number;
  last_seen_at: number;
  revoked_at: number | null;
}

const COLUMNS = "id, user_id, token_hash, device_name, created_at, expires_at, last_seen_at, revoked_at";

export class SessionRepository {
  constructor(private readonly db: Database) {}

  create(input: { userId: string; tokenHash: string; deviceName: string | null; expiresAt: Date }, now: Date = new Date()): AuthSession {
    const id = randomUUID();
    this.db.run(
      `INSERT INTO sessions (${COLUMNS}) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)`,
      id,
      input.userId,
      input.tokenHash,
      input.deviceName,
      now.getTime(),
      input.expiresAt.getTime(),
      now.getTime(),
    );
    const created = this.findByTokenHash(input.tokenHash);
    if (!created) throw new Error("Session insert did not persist");
    return created;
  }

  findById(id: string): AuthSession | null {
    const row = this.db.get<SessionRow>(`SELECT ${COLUMNS} FROM sessions WHERE id = ?`, id);
    return row ? SessionRepository.toSession(row) : null;
  }

  findByTokenHash(tokenHash: string): AuthSession | null {
    const row = this.db.get<SessionRow>(`SELECT ${COLUMNS} FROM sessions WHERE token_hash = ?`, tokenHash);
    return row ? SessionRepository.toSession(row) : null;
  }

  listActiveForUser(userId: string, now: Date = new Date()): AuthSession[] {
    const rows = this.db.all<SessionRow>(
      `SELECT ${COLUMNS} FROM sessions WHERE user_id = ? AND revoked_at IS NULL AND expires_at > ? ORDER BY last_seen_at DESC, created_at DESC, id DESC`,
      userId,
      now.getTime(),
    );
    return rows.map(SessionRepository.toSession);
  }

  touch(id: string, lastSeenAt: Date, expiresAt: Date): void {
    this.db.run("UPDATE sessions SET last_seen_at = ?, expires_at = ? WHERE id = ?", lastSeenAt.getTime(), expiresAt.getTime(), id);
  }

  revoke(id: string, now: Date = new Date()): void {
    this.db.run("UPDATE sessions SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL", now.getTime(), id);
  }

  revokeOwned(id: string, userId: string, now: Date = new Date()): boolean {
    const result = this.db.run(
      "UPDATE sessions SET revoked_at = ? WHERE id = ? AND user_id = ? AND revoked_at IS NULL",
      now.getTime(),
      id,
      userId,
    );
    return Number(result.changes) > 0;
  }

  revokeAllForUser(userId: string, now: Date = new Date()): number {
    const result = this.db.run("UPDATE sessions SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL", now.getTime(), userId);
    return Number(result.changes);
  }

  revokeAllForUserExcept(userId: string, keepSessionId: string, now: Date = new Date()): number {
    const result = this.db.run(
      "UPDATE sessions SET revoked_at = ? WHERE user_id = ? AND id != ? AND revoked_at IS NULL",
      now.getTime(),
      userId,
      keepSessionId,
    );
    return Number(result.changes);
  }

  deleteExpired(now: Date = new Date()): number {
    const result = this.db.run("DELETE FROM sessions WHERE expires_at < ? OR revoked_at IS NOT NULL", now.getTime());
    return Number(result.changes);
  }

  private static toSession(row: SessionRow): AuthSession {
    return {
      id: row.id,
      userId: row.user_id,
      tokenHash: row.token_hash,
      deviceName: row.device_name,
      createdAt: new Date(Number(row.created_at)),
      expiresAt: new Date(Number(row.expires_at)),
      lastSeenAt: new Date(Number(row.last_seen_at)),
      revokedAt: dateFromSql(row.revoked_at),
    };
  }
}
