import type { Database } from "../db/Database.js";

export type AuditVerificationMode = "incremental" | "full";

/** The verified prefix of the audit chain: every row up to lastId checked out. */
export interface AuditChainPosition {
  readonly lastId: number;
  readonly lastHash: string | null;
  readonly verifiedCount: number;
  readonly legacyCount: number;
}

export interface AuditVerificationOutcome {
  readonly ok: boolean;
  readonly firstBrokenId: number | null;
  readonly mode: AuditVerificationMode;
  readonly at: Date;
}

export interface AuditCheckpoint {
  readonly position: AuditChainPosition;
  readonly outcome: AuditVerificationOutcome;
}

interface CheckpointRow {
  last_id: number;
  last_hash: string | null;
  verified_count: number;
  legacy_count: number;
  result_ok: number;
  result_first_broken_id: number | null;
  result_mode: string;
  result_at: number;
}

/**
 * The checkpoint is derived state (a full verification rebuilds it), so its
 * table lives outside the versioned migration ladder shared with the Python
 * account service. ensureTable is idempotent; a missing table or row means
 * "verify from the first row".
 */
export class AuditCheckpointRepository {
  constructor(private readonly db: Database) {}

  ensureTable(): void {
    this.db.exec(`CREATE TABLE IF NOT EXISTS audit_chain_checkpoint (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      last_id INTEGER NOT NULL,
      last_hash TEXT,
      verified_count INTEGER NOT NULL,
      legacy_count INTEGER NOT NULL,
      result_ok INTEGER NOT NULL CHECK (result_ok IN (0, 1)),
      result_first_broken_id INTEGER,
      result_mode TEXT NOT NULL,
      result_at INTEGER NOT NULL
    )`);
  }

  find(): AuditCheckpoint | null {
    if (!this.db.get("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'audit_chain_checkpoint'")) return null;
    const row = this.db.get<CheckpointRow>(
      "SELECT last_id, last_hash, verified_count, legacy_count, result_ok, result_first_broken_id, result_mode, result_at FROM audit_chain_checkpoint WHERE id = 1",
    );
    if (!row) return null;
    return {
      position: {
        lastId: Number(row.last_id),
        lastHash: row.last_hash,
        verifiedCount: Number(row.verified_count),
        legacyCount: Number(row.legacy_count),
      },
      outcome: {
        ok: Number(row.result_ok) === 1,
        firstBrokenId: row.result_first_broken_id === null ? null : Number(row.result_first_broken_id),
        mode: row.result_mode === "full" ? "full" : "incremental",
        at: new Date(Number(row.result_at)),
      },
    };
  }

  save(checkpoint: AuditCheckpoint): void {
    this.ensureTable();
    const { position, outcome } = checkpoint;
    this.db.run(
      `INSERT INTO audit_chain_checkpoint (id, last_id, last_hash, verified_count, legacy_count, result_ok, result_first_broken_id, result_mode, result_at)
       VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET last_id = excluded.last_id, last_hash = excluded.last_hash,
         verified_count = excluded.verified_count, legacy_count = excluded.legacy_count, result_ok = excluded.result_ok,
         result_first_broken_id = excluded.result_first_broken_id, result_mode = excluded.result_mode, result_at = excluded.result_at`,
      position.lastId,
      position.lastHash,
      position.verifiedCount,
      position.legacyCount,
      outcome.ok ? 1 : 0,
      outcome.firstBrokenId,
      outcome.mode,
      outcome.at.getTime(),
    );
  }
}
