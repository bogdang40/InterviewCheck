import type { SessionRepository } from "../repositories/SessionRepository.js";

export const SESSION_PRUNE_INTERVAL_MS = 60 * 60_000;

/**
 * Deletes expired and revoked sessions on a fixed interval. The timer is
 * unref'd so it never keeps the process alive on its own, and stop() is
 * called from Container.close() during shutdown.
 */
export class SessionPruneScheduler {
  private timer: NodeJS.Timeout | null = null;

  constructor(
    private readonly sessions: Pick<SessionRepository, "deleteExpired">,
    private readonly intervalMs: number = SESSION_PRUNE_INTERVAL_MS,
    private readonly clock: () => Date = () => new Date(),
  ) {}

  get isRunning(): boolean {
    return this.timer !== null;
  }

  start(): void {
    if (this.timer) return;
    this.timer = setInterval(() => this.pruneNow(), this.intervalMs);
    this.timer.unref();
  }

  stop(): void {
    if (!this.timer) return;
    clearInterval(this.timer);
    this.timer = null;
  }

  /** Returns the number of sessions removed; a failure is logged without its message and retried next tick. */
  pruneNow(): number {
    try {
      const pruned = this.sessions.deleteExpired(this.clock());
      if (pruned > 0) console.log(`[server] pruned ${pruned} expired session(s)`);
      return pruned;
    } catch (error) {
      console.error(`[server] session prune failed with ${(error as Error).constructor?.name ?? "Error"}`);
      return 0;
    }
  }
}
