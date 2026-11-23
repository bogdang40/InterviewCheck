export interface RateLimitOptions {
  readonly windowMs: number;
  readonly max: number;
  /** Most distinct keys tracked at once; keys beyond it share one overflow bucket. */
  readonly maxBuckets?: number;
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

interface Bucket {
  count: number;
  resetAt: number;
}

const DEFAULT_MAX_BUCKETS = 5000;

/** Key reported for the shared overflow bucket in snapshots. */
export const OVERFLOW_BUCKET_KEY = "overflow";

/**
 * Fixed window, in memory limiter. One process is enough for this service;
 * swap the store if you ever run several replicas.
 *
 * Capacity is bounded and fails closed: when every slot holds a live bucket,
 * expired buckets are evicted first, and if none have expired the new key is
 * counted in a single shared overflow bucket with the same limit. Live
 * buckets are never dropped, so flooding the table with fresh keys cannot
 * reset anyone's count (an attacker's included); it can only exhaust the
 * overflow allowance, which then answers 429 to new keys until it resets.
 */
export class FixedWindowRateLimiter {
  private readonly buckets = new Map<string, Bucket>();
  private overflow: Bucket | null = null;
  private readonly maxBuckets: number;

  constructor(
    private readonly options: RateLimitOptions,
    private readonly clock: () => number = () => Date.now(),
  ) {
    this.maxBuckets = Math.max(1, options.maxBuckets ?? DEFAULT_MAX_BUCKETS);
  }

  /** Returns remaining allowance (or -1 when over the limit) and Retry-After seconds. */
  hitWithRetry(key: string): RateLimitHit {
    const now = this.clock();
    const bucket = this.bucketFor(key, now);
    bucket.count += 1;
    if (bucket.count > this.options.max) {
      return { remaining: -1, retryAfterSeconds: Math.max(1, Math.ceil((bucket.resetAt - now) / 1000)) };
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
      active.push(this.describe(key, bucket, now));
    }
    if (this.overflow && this.overflow.resetAt > now) active.push(this.describe(OVERFLOW_BUCKET_KEY, this.overflow, now));
    return active;
  }

  clear(key?: string): number {
    if (key === OVERFLOW_BUCKET_KEY && !this.buckets.has(key)) {
      const had = this.overflow ? 1 : 0;
      this.overflow = null;
      return had;
    }
    if (key !== undefined) {
      return this.buckets.delete(key) ? 1 : 0;
    }
    const count = this.buckets.size + (this.overflow ? 1 : 0);
    this.buckets.clear();
    this.overflow = null;
    return count;
  }

  private bucketFor(key: string, now: number): Bucket {
    const existing = this.buckets.get(key);
    if (existing && existing.resetAt > now) return existing;
    if (existing) this.buckets.delete(key);
    if (this.buckets.size >= this.maxBuckets) this.evictExpired(now);
    if (this.buckets.size >= this.maxBuckets) return this.overflowBucket(now);
    const fresh = { count: 0, resetAt: now + this.options.windowMs };
    this.buckets.set(key, fresh);
    return fresh;
  }

  private overflowBucket(now: number): Bucket {
    if (!this.overflow || this.overflow.resetAt <= now) this.overflow = { count: 0, resetAt: now + this.options.windowMs };
    return this.overflow;
  }

  /**
   * Every bucket has the same window and a bucket is re-inserted when its
   * window restarts, so insertion order is expiry order and the scan can stop
   * at the first live bucket.
   */
  private evictExpired(now: number): void {
    for (const [key, bucket] of this.buckets) {
      if (bucket.resetAt > now) break;
      this.buckets.delete(key);
    }
  }

  private describe(key: string, bucket: Bucket, now: number): RateLimitBucketSnapshot {
    return {
      key,
      count: bucket.count,
      max: this.options.max,
      remaining: Math.max(0, this.options.max - bucket.count),
      resetAt: bucket.resetAt,
      resetInSeconds: Math.max(1, Math.ceil((bucket.resetAt - now) / 1000)),
    };
  }
}
