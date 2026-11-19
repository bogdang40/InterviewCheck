import { Database } from "../db/Database.js";

export interface AuditEntry {
  readonly id: number;
  readonly at: Date;
  readonly actorUserId: string | null;
  readonly action: string;
  readonly targetUserId: string | null;
  readonly details: Record<string, unknown> | null;
}

export interface AuditFilter {
  readonly q?: string | undefined;
  readonly action?: string | undefined;
  readonly actor?: string | undefined;
  readonly since?: Date | undefined;
  readonly until?: Date | undefined;
  readonly beforeId?: number | undefined;
  readonly limit?: number | undefined;
}

export interface AuditPage {
  readonly entries: AuditEntry[];
  readonly nextBeforeId: number | null;
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
    return rows.map(AuditLogRepository.toEntry);
  }

  search(filter: AuditFilter = {}): AuditPage {
    const limit = Math.max(1, Math.min(filter.limit ?? 100, 200));
    const clauses: string[] = [];
    const params: Array<string | number> = [];

    const q = filter.q?.trim().toLowerCase();
    if (q) {
      clauses.push(
        "INSTR(LOWER(COALESCE(action, '') || ' ' || COALESCE(actor_user_id, '') || ' ' || COALESCE(target_user_id, '') || ' ' || COALESCE(details, '')), ?) > 0",
      );
      params.push(q);
    }

    const action = filter.action?.trim().toLowerCase();
    if (action) {
      clauses.push("INSTR(LOWER(COALESCE(action, '')), ?) > 0");
      params.push(action);
    }

    const actor = filter.actor?.trim().toLowerCase();
    if (actor) {
      clauses.push("INSTR(LOWER(COALESCE(actor_user_id, '')), ?) > 0");
      params.push(actor);
    }

    if (filter.since) {
      clauses.push("at >= ?");
      params.push(filter.since.getTime());
    }

    if (filter.until) {
      clauses.push("at <= ?");
      params.push(filter.until.getTime());
    }

    if (filter.beforeId !== undefined) {
      clauses.push("id < ?");
      params.push(filter.beforeId);
    }

    const where = clauses.length ? `WHERE ${clauses.join(" AND ")}` : "";
    const rows = this.db.all<AuditRow>(
      `SELECT id, at, actor_user_id, action, target_user_id, details FROM audit_log ${where} ORDER BY id DESC LIMIT ?`,
      ...params,
      limit + 1,
    );

    const page = rows.slice(0, limit).map(AuditLogRepository.toEntry);
    const last = page[page.length - 1];
    return {
      entries: page,
      nextBeforeId: rows.length > limit && last ? last.id : null,
    };
  }

  private static toEntry(row: AuditRow): AuditEntry {
    return {
      id: Number(row.id),
      at: new Date(Number(row.at)),
      actorUserId: row.actor_user_id,
      action: row.action,
      targetUserId: row.target_user_id,
      details: row.details ? (JSON.parse(row.details) as Record<string, unknown>) : null,
    };
  }
}
