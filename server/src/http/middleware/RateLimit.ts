import type { MiddlewareHandler } from "hono";
import type { AuthEnv } from "./Authenticate.js";
import type { ClientAddressResolver } from "./ClientAddressResolver.js";
import type { FixedWindowRateLimiter, RateLimitHit } from "./FixedWindowRateLimiter.js";

export { ClientAddressResolver, TRUSTED_PROXY_HEADERS, type TrustedProxyHeader } from "./ClientAddressResolver.js";
export { FixedWindowRateLimiter, type RateLimitBucketSnapshot, type RateLimitHit, type RateLimitOptions } from "./FixedWindowRateLimiter.js";

function tooManyRequests(c: Parameters<MiddlewareHandler>[0], hit: RateLimitHit): Response {
  return c.json(
    { error: { code: "rate_limited", message: "Too many attempts. Try again in a minute." } },
    429,
    { "Retry-After": String(hit.retryAfterSeconds) },
  );
}

/** Limits by client address as resolved under the proxy trust configuration. */
export function rateLimit(limiter: FixedWindowRateLimiter, addresses: ClientAddressResolver): MiddlewareHandler {
  return async (c, next) => {
    const hit = limiter.hitWithRetry(addresses.resolve(c));
    if (hit.remaining < 0) return tooManyRequests(c, hit);
    await next();
  };
}

/** Limits by authenticated user; must run after authenticate(). */
export function rateLimitUser(limiter: FixedWindowRateLimiter): MiddlewareHandler<AuthEnv> {
  return async (c, next) => {
    const hit = limiter.hitWithRetry(`user:${c.get("user").id}`);
    if (hit.remaining < 0) return tooManyRequests(c, hit);
    await next();
  };
}
