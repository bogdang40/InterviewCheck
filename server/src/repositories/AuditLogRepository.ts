import { createHash } from "node:crypto";
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

export interface AuditChainVerification {
  readonly ok: boolean;
  readonly verifiedCount: number;
  readonly legacyUnchainedCount: number;
  readonly firstBrokenId: number | null;
  readonly headHash: string | null;
}

export interface AuditChainRow {
  readonly id: number;
  readonly at: number;
  readonly actorUserId: string | null;
  readonly action: string;
  readonly targetUserId: string | null;
  readonly detailsJson: string | null;
  readonly prevHash: string | null;
  readonly entryHash: string | null;
}

interface AuditRow {
  id: number;
  at: number;
  actor_user_id: string | null;
  action: string;
  target_user_id: string | null;
  details: string | null;
}

interface AuditVerifyRow extends AuditRow {
  prev_hash: string | null;
  entry_hash: string | null;
}

export class AuditLogRepository {
  constructor(private readonly db: Database) {}

  record(entry: { actorUserId: string | null; action: string; targetUserId?: string | null; details?: Record<string, unknown> }, now: Date = new Date()): void {
    const at = now.getTime();
    const targetUserId = entry.targetUserId ?? null;
    const detailsJson = entry.details ? JSON.stringify(entry.details) : null;
    const savepoint = "sp_audit_record";
    this.db.exec(`SAVEPOINT ${savepoint}`);
    try {
      const prev = this.db.get<{ entry_hash: string | null }>("SELECT entry_hash FROM audit_log ORDER BY id DESC LIMIT 1");
      const prevHash = prev?.entry_hash ?? null;
      const entryHash = AuditLogRepository.computeEntryHash({
        prevHash,
        at,
        actorUserId: entry.actorUserId,
        action: entry.action,
        targetUserId,
        detailsJson,
      });
      this.db.run(
        "INSERT INTO audit_log (at, actor_user_id, action, target_user_id, details, prev_hash, entry_hash) VALUES (?, ?, ?, ?, ?, ?, ?)",
        at,
        entry.actorUserId,
        entry.action,
        targetUserId,
        detailsJson,
        prevHash,
        entryHash,
      );
      this.db.exec(`RELEASE SAVEPOINT ${savepoint}`);
    } catch (error) {
      this.db.exec(`ROLLBACK TO SAVEPOINT ${savepoint}`);
      this.db.exec(`RELEASE SAVEPOINT ${savepoint}`);
      throw error;
    }
  }

  /** Chain columns for rows after `afterId`, in id order, at most `limit` rows. */
  chainRowsAfter(afterId: number, limit: number): AuditChainRow[] {
    return this.db
      .all<AuditVerifyRow>(
        "SELECT id, at, actor_user_id, action, target_user_id, details, prev_hash, entry_hash FROM audit_log WHERE id > ? ORDER BY id ASC LIMIT ?",
        afterId,
        limit,
      )
      .map((row) => ({
        id: Number(row.id),
        at: Number(row.at),
        actorUserId: row.actor_user_id,
        action: row.action,
        targetUserId: row.target_user_id,
        detailsJson: row.details,
        prevHash: row.prev_hash,
        entryHash: row.entry_hash,
      }));
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

  static computeEntryHash(input: {
    prevHash: string | null;
    at: number;
    actorUserId: string | null;
    action: string;
    targetUserId: string | null;
    detailsJson: string | null;
  }): string {
    const payload = `${input.prevHash ?? "GENESIS"}|${input.at}|${input.actorUserId ?? ""}|${input.action}|${input.targetUserId ?? ""}|${input.detailsJson ?? ""}`;
    return createHash("sha256").update(payload, "utf8").digest("hex");
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
