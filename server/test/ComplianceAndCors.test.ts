import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { LATEST_SCHEMA_VERSION } from "../src/db/Migrations.js";
import type { SignedInResponse } from "../src/services/AuthService.js";
import { TotpService, type TotpSetupView } from "../src/services/TotpService.js";
import { buildHarness, get, json, patch, post, type TestHarness } from "./support/TestContainer.js";

interface ComplianceSummary {
  schemaVersion: number;
  usersTotal: number;
  adminsTotal: number;
  disabledUsersTotal: number;
  totpEnabledUsersTotal: number;
  activeSessionsTotal: number;
  activeApiTokensTotal: number;
  auditChainOk: boolean;
}

describe("M21-W3 CORS preflight rejection, security headers, and compliance summary", () => {
  let harness: TestHarness;
  let adminToken: string;
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
    const member = await json<SignedInResponse>(
      await post(harness.app, "/v1/auth/signup", {
        email: "member@example.com",
        password: "a-long-password",
        deviceName: "Member Laptop",
      }),
    );
    memberToken = member.token;
    memberId = member.user.id;
  });

  afterEach(() => {
    harness.container.close();
  });

  it("sets Referrer-Policy: no-referrer on all responses and denies OPTIONS preflight with 403", async () => {
    for (const path of ["/health", "/v1/does-not-exist", "/v1/admin/compliance/summary"]) {
      const res = await get(harness.app, path, path.startsWith("/v1/admin") ? adminToken : undefined);
      expect(res.headers.get("referrer-policy")).toBe("no-referrer");
      expect(res.headers.get("access-control-allow-origin")).toBeNull();
    }

    for (const target of [
      { path: "/v1/auth/login", origin: "https://evil.example", method: "POST" },
      { path: "/v1/admin/compliance/summary", origin: "https://evil.example", method: "GET" },
      { path: "/health", origin: "http://127.0.0.1:3000", method: "GET" },
    ]) {
      const preflight = await harness.app.request(target.path, {
        method: "OPTIONS",
        headers: {
          origin: target.origin,
          "access-control-request-method": target.method,
          "access-control-request-headers": "authorization, content-type",
        },
      });
      expect(preflight.status).toBe(403);
      expect(preflight.headers.get("access-control-allow-origin")).toBeNull();
      expect(preflight.headers.get("referrer-policy")).toBe("no-referrer");
      expect(preflight.headers.get("cache-control")).toBe("no-store");
      expect(preflight.headers.get("x-content-type-options")).toBe("nosniff");
      expect(preflight.headers.get("x-frame-options")).toBe("DENY");
      expect(await json(preflight)).toMatchObject({ error: { code: "forbidden" } });
    }

    const plainOptions = await harness.app.request("/health", { method: "OPTIONS" });
    expect(plainOptions.status).toBe(404);
    expect(plainOptions.headers.get("access-control-allow-origin")).toBeNull();
    expect(plainOptions.headers.get("referrer-policy")).toBe("no-referrer");
  });

  it("enforces admin auth and returns accurate v8 compliance summary without PII", async () => {
    expect((await get(harness.app, "/v1/admin/compliance/summary")).status).toBe(401);
    expect((await get(harness.app, "/v1/admin/compliance/summary", memberToken)).status).toBe(403);

    const disabledUser = await json<SignedInResponse>(
      await post(harness.app, "/v1/auth/signup", {
        email: "disabled@example.com",
        password: "a-long-password",
        deviceName: "Temp Device",
      }),
    );
    expect(
      (await patch(harness.app, `/v1/admin/users/${disabledUser.user.id}`, { disabled: true }, adminToken)).status,
    ).toBe(200);

    const setup = await json<TotpSetupView>(await post(harness.app, "/v1/auth/totp/setup", {}, memberToken));
    const totpCode = TotpService.generateTotpCode(setup.secret, harness.clock.now.getTime());
    expect((await post(harness.app, "/v1/auth/totp/verify", { code: totpCode }, memberToken)).status).toBe(200);

    const tokenRes = await post(
      harness.app,
      "/v1/auth/tokens",
      { name: "Compliance Scanner", scopes: ["read:interviews"], ttlDays: 7 },
      memberToken,
    );
    expect(tokenRes.status).toBe(201);
    const createdToken = await json<{ token: string }>(tokenRes);

    const res = await get(harness.app, "/v1/admin/compliance/summary", adminToken);
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(res.headers.get("referrer-policy")).toBe("no-referrer");

    const rawText = await res.text();
    for (const sensitive of [
      "owner@example.com",
      "member@example.com",
      "disabled@example.com",
      adminToken,
      memberToken,
      createdToken.token,
      setup.secret,
    ]) {
      expect(rawText).not.toContain(sensitive);
    }

    const summary = JSON.parse(rawText) as ComplianceSummary;
    expect(summary).toEqual({
      schemaVersion: LATEST_SCHEMA_VERSION,
      usersTotal: 3,
      adminsTotal: 1,
      disabledUsersTotal: 1,
      totpEnabledUsersTotal: 1,
      activeSessionsTotal: 2,
      activeApiTokensTotal: 1,
      auditChainOk: true,
    });
    expect(harness.container.database.userVersion()).toBe(LATEST_SCHEMA_VERSION);

    // Advance clock past 7-day token TTL while admin session (30d) stays active
    harness.clock.now = new Date(harness.clock.now.getTime() + 8 * 86_400_000);
    const afterExpiry = await json<ComplianceSummary>(await get(harness.app, "/v1/admin/compliance/summary", adminToken));
    expect(afterExpiry.activeApiTokensTotal).toBe(0);
    expect(afterExpiry.activeSessionsTotal).toBe(2);

    // Tamper audit_log and verify auditChainOk flips to false
    harness.container.database.run("UPDATE audit_log SET details = ? WHERE id = 1", '{"tampered":true}');
    const tampered = await json<ComplianceSummary>(await get(harness.app, "/v1/admin/compliance/summary", adminToken));
    expect(tampered.auditChainOk).toBe(false);
  });

  it("enforces readGuard rate limit on /v1/admin/compliance/summary", async () => {
    // adminReadLimiter max is 120 per minute
    for (let i = 0; i < 120; i += 1) {
      const ok = await get(harness.app, "/v1/admin/compliance/summary", adminToken);
      expect(ok.status).toBe(200);
    }
    const limited = await get(harness.app, "/v1/admin/compliance/summary", adminToken);
    expect(limited.status).toBe(429);
    expect(Number(limited.headers.get("retry-after"))).toBeGreaterThanOrEqual(1);
  });
});
