import { createHash } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { ClientAddressResolver, FixedWindowRateLimiter } from "../src/http/middleware/RateLimit.js";
import type { SignedInResponse } from "../src/services/AuthService.js";
import type { CreatedApiTokenView, RateLimitEntryView, SessionView } from "../src/services/SecurityService.js";
import { buildHarness, get, json, post, type TestHarness } from "./support/TestContainer.js";

function del(app: TestHarness["app"], path: string, token?: string): Promise<Response> {
  return app.request(path, {
    method: "DELETE",
    headers: token ? { authorization: `Bearer ${token}` } : {},
  });
}

describe("M15 security controls: sessions, scoped API tokens, and rate-limit controls", () => {
  let harness: TestHarness;
  let adminToken: string;
  let adminId: string;
  let memberToken: string;
  let memberId: string;

  beforeEach(async () => {
    harness = buildHarness({ TRUST_PROXY: true });
    const admin = await json<SignedInResponse>(
      await post(harness.app, "/v1/auth/signup", {
        email: "owner@example.com",
        password: "a-long-password",
        deviceName: "Admin Mac",
        adminSecret: "bootstrap-secret",
      }),
    );
    adminToken = admin.token;
    adminId = admin.user.id;
    const member = await json<SignedInResponse>(
      await post(harness.app, "/v1/auth/signup", {
        email: "member@example.com",
        password: "a-long-password",
        deviceName: "Laptop A",
      }),
    );
    memberToken = member.token;
    memberId = member.user.id;
  });

  afterEach(() => {
    harness.container.close();
  });

  it("lists active sessions without tokenHash and revokes owned sessions with audit logging", async () => {
    const second = await json<SignedInResponse>(
      await post(harness.app, "/v1/auth/login", {
        email: "member@example.com",
        password: "a-long-password",
        deviceName: "Desktop B",
      }),
    );
    const listRes = await get(harness.app, "/v1/auth/sessions", second.token);
    expect(listRes.status).toBe(200);
    const listBody = await json<{ sessions: SessionView[] }>(listRes);
    expect(listBody.sessions).toHaveLength(2);
    expect(JSON.stringify(listBody)).not.toContain("tokenHash");
    expect(JSON.stringify(listBody)).not.toContain("token_hash");

    const current = listBody.sessions.find((s) => s.isCurrent);
    const other = listBody.sessions.find((s) => !s.isCurrent);
    expect(current?.deviceName).toBe("Desktop B");
    expect(other?.deviceName).toBe("Laptop A");

    const revokeRes = await del(harness.app, `/v1/auth/sessions/${other!.id}`, second.token);
    expect(revokeRes.status).toBe(200);
    expect((await get(harness.app, "/v1/me", memberToken)).status).toBe(401);
    expect((await get(harness.app, "/v1/me", second.token)).status).toBe(200);

    const afterList = await json<{ sessions: SessionView[] }>(await get(harness.app, "/v1/auth/sessions", second.token));
    expect(afterList.sessions).toHaveLength(1);
    expect(afterList.sessions[0]!.id).toBe(current!.id);

    expect((await del(harness.app, `/v1/auth/sessions/${other!.id}`, second.token)).status).toBe(404);
    expect((await del(harness.app, `/v1/auth/sessions/${current!.id}`, adminToken)).status).toBe(404);
    expect((await del(harness.app, "/v1/auth/sessions/not-a-uuid", second.token)).status).toBe(400);

    const audit = harness.container.audit.search({ action: "auth.session_revoke" });
    expect(audit.entries).toHaveLength(1);
    expect(audit.entries[0]!.actorUserId).toBe(memberId);
  });

  it("creates, lists, verifies, and revokes scoped ic_tok_* API tokens with zero secret leakage", async () => {
    const createRes = await post(
      harness.app,
      "/v1/auth/tokens",
      { name: "CI Exporter", scopes: ["read:interviews", "export:reports"], ttlDays: 30 },
      memberToken,
    );
    expect(createRes.status).toBe(201);
    const created = await json<CreatedApiTokenView>(createRes);
    expect(created.token).toMatch(/^ic_tok_[A-Za-z0-9_-]{32,}$/);
    expect(created.apiToken.tokenPrefix).toBe(created.token.slice(0, 14));
    expect(created.apiToken.scopes).toEqual(["read:interviews", "export:reports"]);
    expect(created.apiToken.expiresAt).not.toBeNull();

    const dbRow = harness.container.database.get<{ token_hash: string; token_prefix: string }>(
      "SELECT token_hash, token_prefix FROM api_tokens WHERE id = ?",
      created.apiToken.id,
    );
    const expectedHash = createHash("sha256").update(created.token, "utf8").digest("hex");
    expect(dbRow?.token_hash).toBe(expectedHash);
    expect(dbRow?.token_prefix).toBe(created.token.slice(0, 14));

    const listRes = await get(harness.app, "/v1/auth/tokens", memberToken);
    expect(listRes.status).toBe(200);
    const listText = await listRes.text();
    expect(listText).not.toContain(created.token);
    expect(listText).not.toContain(expectedHash);
    expect(listText).not.toContain("tokenHash");

    expect((await get(harness.app, "/v1/auth/sessions", created.token)).status).toBe(401);
    expect((await get(harness.app, "/v1/auth/tokens", created.token)).status).toBe(401);

    const verified = harness.container.security.verifyApiToken(created.token, "export:reports");
    expect(verified?.user.id).toBe(memberId);
    expect(harness.container.security.verifyApiToken(created.token, "write:interviews")).toBeNull();

    harness.clock.now = new Date(harness.clock.now.getTime() + 31 * 86_400_000);
    expect(harness.container.security.verifyApiToken(created.token, "read:interviews")).toBeNull();

    harness.clock.now = new Date("2026-09-02T12:00:00Z");
    expect((await del(harness.app, `/v1/auth/tokens/${created.apiToken.id}`, adminToken)).status).toBe(404);
    expect((await del(harness.app, `/v1/auth/tokens/${created.apiToken.id}`, memberToken)).status).toBe(200);
    expect(harness.container.security.verifyApiToken(created.token, "read:interviews")).toBeNull();
    expect((await del(harness.app, `/v1/auth/tokens/${created.apiToken.id}`, memberToken)).status).toBe(404);

    const afterList = await json<{ tokens: unknown[] }>(await get(harness.app, "/v1/auth/tokens", memberToken));
    expect(afterList.tokens).toHaveLength(0);
  });

  it("enforces admin:models scope guard, TTL bounds, and scope validation on token creation", async () => {
    const forbidden = await post(
      harness.app,
      "/v1/auth/tokens",
      { name: "Escalation", scopes: ["admin:models"] },
      memberToken,
    );
    expect(forbidden.status).toBe(403);

    const adminCreated = await post(
      harness.app,
      "/v1/auth/tokens",
      { name: "Admin Fleet", scopes: ["admin:models", "read:telemetry"], ttlDays: 365 },
      adminToken,
    );
    expect(adminCreated.status).toBe(201);
    const adminBody = await json<CreatedApiTokenView>(adminCreated);
    expect(harness.container.security.verifyApiToken(adminBody.token, "admin:models")?.user.id).toBe(adminId);

    for (const invalid of [
      { name: "Bad Scope", scopes: ["delete:everything"] },
      { name: "Empty Scopes", scopes: [] },
      { name: "Zero TTL", scopes: ["read:interviews"], ttlDays: 0 },
      { name: "Over Max TTL", scopes: ["read:interviews"], ttlDays: 366 },
      { name: "   ", scopes: ["read:interviews"] },
    ]) {
      const res = await post(harness.app, "/v1/auth/tokens", invalid, adminToken);
      expect(res.status).toBe(400);
    }
  });

  it("allows admins to inspect and revoke user sessions without disabling the account", async () => {
    await post(harness.app, "/v1/auth/login", {
      email: "member@example.com",
      password: "a-long-password",
      deviceName: "Second Device",
    });

    const nonAdmin = await get(harness.app, `/v1/admin/users/${memberId}/sessions`, memberToken);
    expect(nonAdmin.status).toBe(403);
    expect((await get(harness.app, `/v1/admin/users/${memberId}/sessions`)).status).toBe(401);

    const inspectRes = await get(harness.app, `/v1/admin/users/${memberId}/sessions`, adminToken);
    expect(inspectRes.status).toBe(200);
    const inspected = await json<{ userId: string; sessions: Array<{ id: string; deviceName: string | null }> }>(inspectRes);
    expect(inspected.userId).toBe(memberId);
    expect(inspected.sessions).toHaveLength(2);
    expect(JSON.stringify(inspected)).not.toContain("tokenHash");

    const singleRevoke = await post(
      harness.app,
      `/v1/admin/users/${memberId}/revoke-sessions`,
      { sessionId: inspected.sessions[0]!.id },
      adminToken,
    );
    expect(singleRevoke.status).toBe(200);
    expect(await json(singleRevoke)).toEqual({ userId: memberId, revokedCount: 1 });

    const revokeAll = await post(harness.app, `/v1/admin/users/${memberId}/revoke-sessions`, {}, adminToken);
    expect(revokeAll.status).toBe(200);
    expect(await json(revokeAll)).toEqual({ userId: memberId, revokedCount: 1 });
    expect((await get(harness.app, "/v1/me", memberToken)).status).toBe(401);

    const relogin = await post(harness.app, "/v1/auth/login", { email: "member@example.com", password: "a-long-password" });
    expect(relogin.status).toBe(200);

    const audit = harness.container.audit.search({ action: "admin.revoke_sessions" });
    expect(audit.entries).toHaveLength(2);
    expect((await get(harness.app, "/v1/admin/users/00000000-0000-4000-8000-000000000000/sessions", adminToken)).status).toBe(404);
  });

  it("normalizes IPv6 /64 prefixes, snapshots active buckets, and allows admin unlock without PII leakage", async () => {
    expect(ClientAddressResolver.normalizeAddress("2001:0db8:85a3:0001:0000:8a2e:0370:7334")).toBe("2001:db8:85a3:1::/64");
    expect(ClientAddressResolver.normalizeAddress("2001:db8:85a3:1:ffff::99")).toBe("2001:db8:85a3:1::/64");
    expect(ClientAddressResolver.normalizeAddress("[2001:db8:85a3:2::42]:443")).toBe("2001:db8:85a3:2::/64");
    expect(ClientAddressResolver.normalizeAddress("fe80::1%en0")).toBe("fe80::/64");
    expect(ClientAddressResolver.normalizeAddress("::ffff:192.0.2.10")).toBe("192.0.2.10");
    expect(ClientAddressResolver.normalizeAddress("::ffff:c000:020a")).toBe("192.0.2.10");
    expect(ClientAddressResolver.normalizeAddress("::1")).toBe("::/64");
    expect(ClientAddressResolver.normalizeAddress("2001:db8:1:0:0:0:0:1")).toBe("2001:db8:1::/64");

    let now = 1_000;
    const unitLimiter = new FixedWindowRateLimiter({ windowMs: 10_000, max: 3 }, () => now);
    unitLimiter.hit("k1");
    unitLimiter.hit("k2");
    expect(unitLimiter.snapshot().map((b) => b.key)).toEqual(["k1", "k2"]);
    expect(unitLimiter.clear("k1")).toBe(1);
    expect(unitLimiter.snapshot().map((b) => b.key)).toEqual(["k2"]);
    expect(unitLimiter.clear()).toBe(1);
    expect(unitLimiter.snapshot()).toHaveLength(0);

    for (let i = 0; i < 10; i += 1) {
      const res = await harness.app.request("/v1/auth/login", {
        method: "POST",
        headers: { "content-type": "application/json", "fly-client-ip": `2001:db8:abcd:0001::${i + 1}` },
        body: JSON.stringify({ email: "nobody@example.com", password: "a-long-password" }),
      });
      expect(res.status).toBe(401);
    }

    const blocked = await harness.app.request("/v1/auth/login", {
      method: "POST",
      headers: { "content-type": "application/json", "fly-client-ip": "2001:db8:abcd:1:9999::1" },
      body: JSON.stringify({ email: "nobody@example.com", password: "a-long-password" }),
    });
    expect(blocked.status).toBe(429);

    const otherSubnet = await harness.app.request("/v1/auth/login", {
      method: "POST",
      headers: { "content-type": "application/json", "fly-client-ip": "2001:db8:abcd:2::1" },
      body: JSON.stringify({ email: "nobody@example.com", password: "a-long-password" }),
    });
    expect(otherSubnet.status).toBe(401);

    harness.container.database.run(
      "INSERT INTO login_email_windows (email, start, hits) VALUES (?, ?, ?)",
      "locked-user@example.com",
      harness.clock.now.getTime(),
      10,
    );

    expect((await get(harness.app, "/v1/admin/rate-limits", memberToken)).status).toBe(403);
    expect((await del(harness.app, "/v1/admin/rate-limits", memberToken)).status).toBe(403);
    expect((await del(harness.app, "/v1/admin/rate-limits?keyHash=bad", adminToken)).status).toBe(400);

    const inspectRes = await get(harness.app, "/v1/admin/rate-limits", adminToken);
    expect(inspectRes.status).toBe(200);
    const inspectText = await inspectRes.text();
    expect(inspectText).not.toContain("2001:db8:abcd:1::/64");
    expect(inspectText).not.toContain("locked-user@example.com");

    const parsed = JSON.parse(inspectText) as { entries: RateLimitEntryView[]; total: number };
    const subnet1Hash = createHash("sha256").update("2001:db8:abcd:1::/64", "utf8").digest("hex");
    const subnetEntry = parsed.entries.find((entry) => entry.keyHash === subnet1Hash);
    expect(subnetEntry).toBeDefined();
    expect(subnetEntry!.remaining).toBe(0);

    const unlockOne = await del(harness.app, `/v1/admin/rate-limits?limiter=credential&keyHash=${subnet1Hash}`, adminToken);
    expect(unlockOne.status).toBe(200);
    expect(await json(unlockOne)).toEqual({ cleared: 1 });

    const unblocked = await harness.app.request("/v1/auth/login", {
      method: "POST",
      headers: { "content-type": "application/json", "fly-client-ip": "2001:db8:abcd:1::55" },
      body: JSON.stringify({ email: "nobody@example.com", password: "a-long-password" }),
    });
    expect(unblocked.status).toBe(401);

    const unlockByRawIp = await del(harness.app, "/v1/admin/rate-limits?limiter=credential&key=2001:db8:abcd:1::99", adminToken);
    expect(unlockByRawIp.status).toBe(200);
    expect(await json(unlockByRawIp)).toEqual({ cleared: 1 });

    const clearAll = await del(harness.app, "/v1/admin/rate-limits", adminToken);
    expect(clearAll.status).toBe(200);
    expect(harness.container.database.get<{ n: number }>("SELECT COUNT(*) AS n FROM login_email_windows")?.n).toBe(0);

    const unlockAudit = harness.container.audit.search({ action: "admin.rate_limit_unlock" });
    expect(unlockAudit.entries).toHaveLength(3);
  });

  it("enforces authentication, validation, and CSRF on security endpoints", async () => {
    expect((await get(harness.app, "/v1/auth/sessions")).status).toBe(401);
    expect((await get(harness.app, "/v1/auth/tokens")).status).toBe(401);
    expect((await post(harness.app, "/v1/auth/tokens", { name: "x", scopes: ["read:interviews"] })).status).toBe(401);
    expect((await post(harness.app, `/v1/admin/users/${memberId}/revoke-sessions`, {}, memberToken)).status).toBe(403);
    expect((await post(harness.app, `/v1/admin/users/${memberId}/revoke-sessions`, { sessionId: "bad" }, adminToken)).status).toBe(400);
    expect((await post(harness.app, `/v1/admin/users/${memberId}/revoke-sessions`, { sessionId: "00000000-0000-4000-8000-000000000000" }, adminToken)).status).toBe(404);

    const malformedRes = await harness.app.request(`/v1/admin/users/${memberId}/revoke-sessions`, {
      method: "POST",
      headers: { authorization: `Bearer ${adminToken}`, "content-type": "application/json" },
      body: "{bad",
    });
    expect(malformedRes.status).toBe(400);

    const csrfBlocked = await harness.app.request("/v1/auth/tokens", {
      method: "POST",
      headers: { authorization: `Bearer ${memberToken}`, "content-type": "application/json", origin: "https://evil.example" },
      body: JSON.stringify({ name: "CSRF", scopes: ["read:interviews"] }),
    });
    expect(csrfBlocked.status).toBe(403);

    const noExpiryRes = await post(harness.app, "/v1/auth/tokens", { name: "Perm", scopes: ["read:interviews"], ttlDays: null }, memberToken);
    expect(noExpiryRes.status).toBe(201);
    const noExpiry = await json<CreatedApiTokenView>(noExpiryRes);
    expect(noExpiry.apiToken.expiresAt).toBeNull();
    harness.container.users.update(memberId, { disabled: true });
    expect(harness.container.security.verifyApiToken(noExpiry.token, "read:interviews")).toBeNull();
  });

  it("ignores a spoofed Fly-Client-IP behind an x-forwarded-for proxy so random values cannot escape the limit", async () => {
    harness.container.close();
    harness = buildHarness({ TRUST_PROXY: true, TRUSTED_PROXY_HEADER: "x-forwarded-for" });
    const statuses: number[] = [];
    for (let i = 0; i < 11; i += 1) {
      const res = await harness.app.request("/v1/auth/login", {
        method: "POST",
        headers: { "content-type": "application/json", "fly-client-ip": `198.18.${i}.${i + 1}`, "x-forwarded-for": "203.0.113.50" },
        body: JSON.stringify({ email: `spoof-${i}@example.com`, password: "a-long-password" }),
      });
      statuses.push(res.status);
    }
    expect(statuses.slice(0, 10).every((status) => status === 401)).toBe(true);
    expect(statuses[10]).toBe(429);
  });

  it("fails closed on bucket overflow: live buckets keep their counts and new keys share one limited bucket", () => {
    let now = 0;
    const limiter = new FixedWindowRateLimiter({ windowMs: 1_000, max: 2, maxBuckets: 3 }, () => now);
    limiter.hit("attacker");
    limiter.hit("attacker");
    limiter.hit("b");
    limiter.hit("c");
    expect(limiter.hit("flood-1")).toBe(1);
    expect(limiter.hit("flood-2")).toBe(0);
    expect(limiter.hit("flood-3")).toBe(-1);
    expect(limiter.hit("attacker")).toBe(-1);
    expect(limiter.snapshot().map((bucket) => bucket.key)).toEqual(["attacker", "b", "c", "overflow"]);

    now = 1_000;
    expect(limiter.hit("fresh")).toBe(1);
    expect(limiter.snapshot().map((bucket) => bucket.key)).toEqual(["fresh"]);
  });
});
