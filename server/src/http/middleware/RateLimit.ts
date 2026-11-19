import { isIP } from "node:net";
import type { Context, MiddlewareHandler } from "hono";
import { getConnInfo } from "@hono/node-server/conninfo";
import type { AuthEnv } from "./Authenticate.js";

export interface RateLimitOptions {
  readonly windowMs: number;
  readonly max: number;
}

export interface RateLimitHit {
  readonly remaining: number;
  readonly retryAfterSeconds: number;
}

export interface RateLimitBucketSnapshot {
  readonly key: string;
  readonly count: number;
  readonly max: number;
  readonly remaining: number;
  readonly resetAt: number;
  readonly resetInSeconds: number;
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

  snapshot(): RateLimitBucketSnapshot[] {
    const now = this.clock();
    const active: RateLimitBucketSnapshot[] = [];
    for (const [key, bucket] of this.buckets) {
      if (bucket.resetAt <= now) {
        this.buckets.delete(key);
        continue;
      }
      active.push({
        key,
        count: bucket.count,
        max: this.options.max,
        remaining: Math.max(0, this.options.max - bucket.count),
        resetAt: bucket.resetAt,
        resetInSeconds: Math.max(1, Math.ceil((bucket.resetAt - now) / 1000)),
      });
    }
    return active;
  }

  clear(key?: string): number {
    if (key !== undefined) {
      return this.buckets.delete(key) ? 1 : 0;
    }
    const count = this.buckets.size;
    this.buckets.clear();
    return count;
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
      if (flyClient) return ClientAddressResolver.normalizeAddress(flyClient);
      const hops = (c.req.header("x-forwarded-for") ?? "").split(",").map((hop) => hop.trim()).filter(Boolean);
      const last = hops[hops.length - 1];
      if (last) return ClientAddressResolver.normalizeAddress(last);
    }
    try {
      return ClientAddressResolver.normalizeAddress(getConnInfo(c).remote.address ?? "unknown");
    } catch {
      return "unknown";
    }
  }

  /** Normalizes IPv6 addresses to their canonical /64 prefix; preserves IPv4 and IPv4-mapped IPv6. */
  static normalizeAddress(raw: string): string {
    let addr = raw.trim();
    if (!addr) return "unknown";
    const bracketMatch = /^\[([^\]]+)\](?::\d+)?$/.exec(addr);
    if (bracketMatch?.[1]) addr = bracketMatch[1];
    const ipv4PortMatch = /^(\d+\.\d+\.\d+\.\d+):\d+$/.exec(addr);
    if (ipv4PortMatch?.[1] && isIP(ipv4PortMatch[1]) === 4) return ipv4PortMatch[1];
    const zoneIndex = addr.indexOf("%");
    if (zoneIndex > 0) addr = addr.slice(0, zoneIndex);
    const family = isIP(addr);
    if (family === 4) return addr;
    if (family !== 6) return addr;
    const words = ClientAddressResolver.parseIpv6Words(addr);
    if (!words) return addr;
    if (words[0] === 0 && words[1] === 0 && words[2] === 0 && words[3] === 0 && words[4] === 0 && words[5] === 0xffff) {
      return `${words[6]! >> 8}.${words[6]! & 0xff}.${words[7]! >> 8}.${words[7]! & 0xff}`;
    }
    words[4] = 0;
    words[5] = 0;
    words[6] = 0;
    words[7] = 0;
    return `${ClientAddressResolver.formatIpv6(words)}/64`;
  }

  private static parseIpv6Words(addr: string): number[] | null {
    const doubleColonParts = addr.split("::");
    if (doubleColonParts.length > 2) return null;
    const expandHalf = (half: string): number[] => {
      if (!half) return [];
      const segments = half.split(":");
      const out: number[] = [];
      for (let i = 0; i < segments.length; i += 1) {
        const seg = segments[i]!;
        if (seg.includes(".")) {
          const octets = seg.split(".").map(Number);
          if (octets.length !== 4) return [];
          out.push((octets[0]! << 8) | octets[1]!, (octets[2]! << 8) | octets[3]!);
        } else {
          out.push(Number.parseInt(seg, 16));
        }
      }
      return out;
    };
    const left = expandHalf(doubleColonParts[0] ?? "");
    if (doubleColonParts.length === 1) return left.length === 8 ? left : null;
    const right = expandHalf(doubleColonParts[1] ?? "");
    const missing = 8 - left.length - right.length;
    if (missing < 1) return null;
    return [...left, ...new Array<number>(missing).fill(0), ...right];
  }

  private static formatIpv6(words: readonly number[]): string {
    let bestStart = -1;
    let bestLen = 0;
    let curStart = -1;
    let curLen = 0;
    for (let i = 0; i < 8; i += 1) {
      if (words[i] === 0) {
        if (curStart === -1) curStart = i;
        curLen += 1;
        if (curLen > bestLen) {
          bestStart = curStart;
          bestLen = curLen;
        }
      } else {
        curStart = -1;
        curLen = 0;
      }
    }
    if (bestLen < 2) bestStart = -1;
    const parts: string[] = [];
    for (let i = 0; i < 8; i += 1) {
      if (i === bestStart) {
        parts.push("");
        if (i === 0) parts.push("");
        i += bestLen - 1;
        if (i === 7) parts.push("");
      } else {
        parts.push(words[i]!.toString(16));
      }
    }
    return parts.join(":");
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

export function rateLimitUser(limiter: FixedWindowRateLimiter): MiddlewareHandler<AuthEnv> {
  return async (c, next) => {
    const user = c.get("user");
    const { remaining, retryAfterSeconds } = limiter.hitWithRetry(`user:${user.id}`);
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
