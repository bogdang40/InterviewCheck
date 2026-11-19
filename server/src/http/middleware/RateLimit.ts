import type { Context, MiddlewareHandler } from "hono";
import { getConnInfo } from "@hono/node-server/conninfo";

export interface RateLimitOptions {
  readonly windowMs: number;
  readonly max: number;
}

export interface RateLimitHit {
  readonly remaining: number;
  readonly retryAfterSeconds: number;
}

/**
 * Fixed window, in memory limiter for credential endpoints. One process is
 * enough for this service; swap the store if you ever run several replicas.
 */
export class FixedWindowRateLimiter {
  private readonly buckets = new Map<string, { count: number; resetAt: number }>();

  constructor(
    private readonly options: RateLimitOptions,
    private readonly clock: () => number = () => Date.now(),
  ) {}

  /** Returns remaining allowance (or -1 when over the limit) and Retry-After seconds. */
  hitWithRetry(key: string): RateLimitHit {
    const now = this.clock();
    const bucket = this.buckets.get(key);
    if (!bucket || bucket.resetAt <= now) {
      if (bucket) this.buckets.delete(key);
      const resetAt = now + this.options.windowMs;
      this.buckets.set(key, { count: 1, resetAt });
      this.sweep(now);
      if (1 > this.options.max) {
        return { remaining: -1, retryAfterSeconds: Math.max(1, Math.ceil((resetAt - now) / 1000)) };
      }
      return { remaining: this.options.max - 1, retryAfterSeconds: 0 };
    }
    bucket.count += 1;
    if (bucket.count > this.options.max) {
      const retryAfterSeconds = Math.max(1, Math.ceil((bucket.resetAt - now) / 1000));
      return { remaining: -1, retryAfterSeconds };
    }
    return { remaining: this.options.max - bucket.count, retryAfterSeconds: 0 };
  }

  /** Returns remaining allowance, or -1 when the caller is over the limit. */
  hit(key: string): number {
    return this.hitWithRetry(key).remaining;
  }

  private sweep(now: number): void {
    if (this.buckets.size < 5000) return;
    for (const [key, bucket] of this.buckets) {
      if (bucket.resetAt <= now) this.buckets.delete(key);
    }
    while (this.buckets.size >= 5000) {
      const oldestKey = this.buckets.keys().next().value;
      if (oldestKey === undefined) break;
      this.buckets.delete(oldestKey);
    }
  }
}

/**
 * Picks the address to rate limit on. Forwarded headers are only honoured
 * when TRUST_PROXY is set, and then only the hop the proxy itself appended
 * (the last one), never the client supplied leftmost value.
 */
export class ClientAddressResolver {
  static resolve(c: Context, trustProxy: boolean): string {
    if (trustProxy) {
      const flyClient = c.req.header("fly-client-ip")?.trim();
      if (flyClient) return flyClient;
      const hops = (c.req.header("x-forwarded-for") ?? "").split(",").map((hop) => hop.trim()).filter(Boolean);
      const last = hops[hops.length - 1];
      if (last) return last;
    }
    try {
      return getConnInfo(c).remote.address ?? "unknown";
    } catch {
      return "unknown";
    }
  }
}

export function rateLimit(limiter: FixedWindowRateLimiter, trustProxy: boolean): MiddlewareHandler {
  return async (c, next) => {
    const { remaining, retryAfterSeconds } = limiter.hitWithRetry(ClientAddressResolver.resolve(c, trustProxy));
    if (remaining < 0) {
      return c.json(
        { error: { code: "rate_limited", message: "Too many attempts. Try again in a minute." } },
        429,
        { "Retry-After": String(retryAfterSeconds) },
      );
    }
    await next();
  };
}
