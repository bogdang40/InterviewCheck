import { Database } from "../db/Database.js";

export interface AuditEntry {
  readonly id: number;
  readonly at: Date;
  readonly actorUserId: string | null;
  readonly action: string;
  readonly targetUserId: string | null;
  readonly details: Record<string, unknown> | null;
}

interface AuditRow {
  id: number;
  at: number;
  actor_user_id: string | null;
  action: string;
  target_user_id: string | null;
  details: string | null;
}

export class AuditLogRepository {
  constructor(private readonly db: Database) {}

  record(entry: { actorUserId: string | null; action: string; targetUserId?: string | null; details?: Record<string, unknown> }, now: Date = new Date()): void {
    this.db.run(
      "INSERT INTO audit_log (at, actor_user_id, action, target_user_id, details) VALUES (?, ?, ?, ?, ?)",
      now.getTime(),
      entry.actorUserId,
      entry.action,
      entry.targetUserId ?? null,
      entry.details ? JSON.stringify(entry.details) : null,
    );
  }

  recent(limit = 100): AuditEntry[] {
    const rows = this.db.all<AuditRow>(
      "SELECT id, at, actor_user_id, action, target_user_id, details FROM audit_log ORDER BY at DESC, id DESC LIMIT ?",
      Math.max(1, Math.min(limit, 500)),
    );
    return rows.map((row) => ({
      id: Number(row.id),
      at: new Date(Number(row.at)),
      actorUserId: row.actor_user_id,
      action: row.action,
      targetUserId: row.target_user_id,
      details: row.details ? (JSON.parse(row.details) as Record<string, unknown>) : null,
    }));
  }
}
