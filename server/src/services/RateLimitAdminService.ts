import type { Database } from "../db/Database.js";
import type { User } from "../domain/User.js";
import { ClientAddressResolver, type FixedWindowRateLimiter } from "../http/middleware/RateLimit.js";
import type { AuditLogRepository } from "../repositories/AuditLogRepository.js";
import type { AdminActorGuard } from "./AdminActorGuard.js";
import type { LoginThrottle } from "./LoginThrottle.js";
import { SensitiveKey } from "./SensitiveKey.js";

export type LimiterName = "credential" | "adminRead" | "adminWrite" | "billing" | "totp" | "apiToken";

export interface RateLimitEntryView {
  readonly source: "memory" | "login_email_windows";
  readonly limiter: string;
  readonly keyHash: string;
  readonly maskedKey: string;
  readonly count: number;
  readonly max: number;
  readonly remaining: number;
  readonly resetAt: string;
  readonly resetInSeconds: number;
}

export interface RateLimitClearFilter {
  readonly limiter?: LimiterName | undefined;
  readonly keyHash?: string | undefined;
  readonly key?: string | undefined;
}

/**
 * Admin view over every limiter: the in memory per address and per user
 * buckets and the per account login windows. Keys leave only hashed and
 * masked.
 */
export class RateLimitAdminService {
  constructor(
    private readonly database: Database,
    private readonly audit: AuditLogRepository,
    private readonly limiters: Readonly<Record<LimiterName, FixedWindowRateLimiter>>,
    private readonly loginThrottle: LoginThrottle,
    private readonly adminGuard: AdminActorGuard,
    private readonly clock: () => Date = () => new Date(),
  ) {}

  listRateLimits(): { entries: RateLimitEntryView[]; total: number } {
    const entries: RateLimitEntryView[] = [];
    for (const [name, limiter] of this.limiterEntries()) {
      for (const bucket of limiter.snapshot()) {
        entries.push({
          source: "memory",
          limiter: name,
          keyHash: SensitiveKey.hash(bucket.key),
          maskedKey: SensitiveKey.mask(bucket.key),
          count: bucket.count,
          max: bucket.max,
          remaining: bucket.remaining,
          resetAt: new Date(bucket.resetAt).toISOString(),
          resetInSeconds: bucket.resetInSeconds,
        });
      }
    }
    const now = this.clock();
    const { windowMs, maxFailures } = this.loginThrottle.policy;
    for (const window of this.loginThrottle.activeWindows(now)) {
      const resetAtMs = window.startMs + windowMs;
      entries.push({
        source: "login_email_windows",
        limiter: "credential",
        keyHash: SensitiveKey.hash(window.email),
        maskedKey: SensitiveKey.mask(window.email),
        count: window.hits,
        max: maxFailures,
        remaining: Math.max(0, maxFailures - window.hits),
        resetAt: new Date(resetAtMs).toISOString(),
        resetInSeconds: Math.max(1, Math.ceil((resetAtMs - now.getTime()) / 1000)),
      });
    }
    return { entries, total: entries.length };
  }

  clearRateLimits(actor: User, filter: RateLimitClearFilter = {}): { cleared: number } {
    const now = this.clock();
    return this.database.transaction(() => {
      const currentActor = this.adminGuard.requireActiveAdmin(actor.id);
      const normalizedKey = filter.key ? ClientAddressResolver.normalizeAddress(filter.key) : undefined;
      const targetHash = filter.keyHash?.toLowerCase();
      const targeted = Boolean(targetHash) || filter.key !== undefined;
      const matches = (key: string) =>
        (targetHash !== undefined && SensitiveKey.hash(key) === targetHash) || (filter.key !== undefined && (key === filter.key || key === normalizedKey));
      let cleared = 0;

      for (const [name, limiter] of this.limiterEntries()) {
        if (filter.limiter && filter.limiter !== name) continue;
        if (!targeted) {
          cleared += limiter.clear();
          continue;
        }
        for (const bucket of limiter.snapshot()) {
          if (matches(bucket.key)) cleared += limiter.clear(bucket.key);
        }
      }
      if (!filter.limiter || filter.limiter === "credential") {
        cleared += this.loginThrottle.clear(targeted ? matches : undefined);
      }

      this.audit.record(
        {
          actorUserId: currentActor.id,
          action: "admin.rate_limit_unlock",
          details: { limiter: filter.limiter ?? "all", keyHash: targetHash ?? (normalizedKey ? SensitiveKey.hash(normalizedKey) : null), cleared },
        },
        now,
      );
      return { cleared };
    });
  }

  private limiterEntries(): Array<[LimiterName, FixedWindowRateLimiter]> {
    return Object.entries(this.limiters) as Array<[LimiterName, FixedWindowRateLimiter]>;
  }
}
