import type { Context, MiddlewareHandler } from "hono";
import { getConnInfo } from "@hono/node-server/conninfo";
import { HttpError } from "../HttpError.js";

export interface RateLimitOptions {
  readonly windowMs: number;
  readonly max: number;
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

  /** Returns remaining allowance, or -1 when the caller is over the limit. */
  hit(key: string): number {
    const now = this.clock();
    const bucket = this.buckets.get(key);
    if (!bucket || bucket.resetAt <= now) {
      this.buckets.set(key, { count: 1, resetAt: now + this.options.windowMs });
      this.sweep(now);
      return this.options.max - 1;
    }
    bucket.count += 1;
    return bucket.count > this.options.max ? -1 : this.options.max - bucket.count;
  }

  private sweep(now: number): void {
    if (this.buckets.size < 5000) return;
    for (const [key, bucket] of this.buckets) {
      if (bucket.resetAt <= now) this.buckets.delete(key);
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
    const remaining = limiter.hit(ClientAddressResolver.resolve(c, trustProxy));
    if (remaining < 0) {
      throw new HttpError(429, "rate_limited", "Too many attempts. Try again in a minute.");
    }
    await next();
  };
}
