import { setImmediate as nextTick } from "node:timers/promises";
import type {
  AuditChainPosition,
  AuditCheckpointRepository,
  AuditVerificationMode,
} from "../repositories/AuditCheckpointRepository.js";
import { AuditLogRepository, type AuditChainRow, type AuditChainVerification } from "../repositories/AuditLogRepository.js";

export interface AuditVerificationResult extends AuditChainVerification {
  readonly mode: AuditVerificationMode;
  /** Highest audit id known to be intact after this run. */
  readonly verifiedThroughId: number;
  readonly verifiedAt: string;
}

export interface AuditVerificationSummary {
  readonly ok: boolean;
  readonly mode: AuditVerificationMode;
  readonly firstBrokenId: number | null;
  readonly verifiedAt: string;
}

export interface AuditChainVerifierOptions {
  readonly batchSize?: number;
  readonly yieldToEventLoop?: () => Promise<unknown>;
}

const GENESIS: AuditChainPosition = { lastId: 0, lastHash: null, verifiedCount: 0, legacyCount: 0 };

/**
 * Verifies the audit hash chain without blocking the event loop: rows are
 * read in bounded batches with a yield between batches, and an incremental
 * run starts from the stored checkpoint, so its cost is the rows appended
 * since the last run. Rows before the checkpoint are only rechecked by a full
 * run, which is how tampering with already verified rows is found.
 */
export class AuditChainVerifier {
  private readonly batchSize: number;
  private readonly yieldToEventLoop: () => Promise<unknown>;
  private queue: Promise<unknown> = Promise.resolve();

  constructor(
    private readonly audit: AuditLogRepository,
    private readonly checkpoints: AuditCheckpointRepository,
    private readonly clock: () => Date = () => new Date(),
    options: AuditChainVerifierOptions = {},
  ) {
    this.batchSize = Math.max(1, options.batchSize ?? 500);
    this.yieldToEventLoop = options.yieldToEventLoop ?? (() => nextTick());
  }

  /** Runs are serialized so two concurrent requests cannot interleave checkpoint writes. */
  verify(mode: AuditVerificationMode): Promise<AuditVerificationResult> {
    const run = this.queue.then(() => this.run(mode));
    this.queue = run.catch(() => undefined);
    return run;
  }

  lastResult(): AuditVerificationSummary | null {
    const outcome = this.checkpoints.find()?.outcome;
    return outcome ? { ok: outcome.ok, mode: outcome.mode, firstBrokenId: outcome.firstBrokenId, verifiedAt: outcome.at.toISOString() } : null;
  }

  private async run(mode: AuditVerificationMode): Promise<AuditVerificationResult> {
    let position = mode === "full" ? GENESIS : (this.checkpoints.find()?.position ?? GENESIS);
    let firstBrokenId: number | null = null;
    for (;;) {
      const rows = this.audit.chainRowsAfter(position.lastId, this.batchSize);
      if (rows.length === 0) break;
      for (const row of rows) {
        const next = AuditChainVerifier.advance(position, row);
        if (!next) {
          firstBrokenId = row.id;
          break;
        }
        position = next;
      }
      if (firstBrokenId !== null || rows.length < this.batchSize) break;
      await this.yieldToEventLoop();
    }
    const at = this.clock();
    const ok = firstBrokenId === null;
    this.checkpoints.save({ position, outcome: { ok, firstBrokenId, mode, at } });
    return {
      ok,
      verifiedCount: position.verifiedCount,
      legacyUnchainedCount: position.legacyCount,
      firstBrokenId,
      headHash: position.lastHash,
      mode,
      verifiedThroughId: position.lastId,
      verifiedAt: at.toISOString(),
    };
  }

  /**
   * Returns the position after `row`, or null if the row breaks the chain.
   * Unchained rows are accepted only before the first chained row (data
   * written before chaining existed).
   */
  private static advance(position: AuditChainPosition, row: AuditChainRow): AuditChainPosition | null {
    const seenChained = position.lastHash !== null;
    if (row.entryHash === null) {
      if (seenChained || row.prevHash !== null) return null;
      return { ...position, lastId: row.id, legacyCount: position.legacyCount + 1 };
    }
    if ((row.prevHash ?? null) !== position.lastHash) return null;
    const expected = AuditLogRepository.computeEntryHash({
      prevHash: position.lastHash,
      at: row.at,
      actorUserId: row.actorUserId,
      action: row.action,
      targetUserId: row.targetUserId,
      detailsJson: row.detailsJson,
    });
    if (expected !== row.entryHash) return null;
    return { lastId: row.id, lastHash: row.entryHash, verifiedCount: position.verifiedCount + 1, legacyCount: position.legacyCount };
  }
}
