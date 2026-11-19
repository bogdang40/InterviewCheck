import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { SignedInResponse } from "../src/services/AuthService.js";
import { buildHarness, get, json, patch, post, type TestHarness } from "./support/TestContainer.js";

const SQLI_PAYLOADS = [
  "' OR '1'='1",
  "\" OR \"1\"=\"1",
  "'; DROP TABLE audit_log; --",
  "admin' UNION SELECT 1,2,3--",
  "%",
  "_",
  "\\%",
  "\\_",
  "a\u0000b",
];

describe("security fuzzing across AuthRoutes, BillingRoutes, and AdminRoutes", () => {
  let harness: TestHarness;
  let adminToken: string;
  let memberToken: string;
  let memberId: string;

  beforeEach(async () => {
    harness = buildHarness();
    const admin = await json<SignedInResponse>(
      await post(harness.app, "/v1/auth/signup", {
        email: "owner@example.com",
        password: "a-long-password",
        adminSecret: "bootstrap-secret",
      }),
    );
    adminToken = admin.token;
    const member = await json<SignedInResponse>(
      await post(harness.app, "/v1/auth/signup", { email: "member@example.com", password: "a-long-password" }),
    );
    memberToken = member.token;
    memberId = member.user.id;
  });

  afterEach(() => {
    harness.container.close();
  });

  it("neutralizes SQLi and LIKE wildcards in admin user and audit queries", async () => {
    for (const payload of SQLI_PAYLOADS) {
      const encoded = encodeURIComponent(payload);
      const usersRes = await get(harness.app, `/v1/admin/users?q=${encoded}`, adminToken);
      expect(usersRes.status).toBe(200);
      expect((await json<{ users: unknown[] }>(usersRes)).users).toHaveLength(0);

      for (const param of ["q", "action", "actor"]) {
        const auditRes = await get(harness.app, `/v1/admin/audit?${param}=${encoded}`, adminToken);
        expect(auditRes.status).toBe(200);
        expect((await json<{ entries: unknown[] }>(auditRes)).entries).toHaveLength(0);
      }
    }
    const intact = await json<{ entries: unknown[] }>(await get(harness.app, "/v1/admin/audit", adminToken));
    expect(intact.entries.length).toBeGreaterThanOrEqual(2);
  });

  it("rejects invalid UUIDs, dates, limits, and malformed JSON bodies", async () => {
    for (const badId of ["not-a-uuid", "../etc/passwd", "12345", "00000000-0000-0000-0000-00000000000g"]) {
      expect((await get(harness.app, `/v1/admin/users/${encodeURIComponent(badId)}`, adminToken)).status).toBe(400);
      expect((await patch(harness.app, `/v1/admin/users/${encodeURIComponent(badId)}`, { disabled: true }, adminToken)).status).toBe(400);
    }
    for (const badDate of ["2026-10-01T00:00:00", "2026-10-01", "invalid", "2026-02-30T10:00:00Z"]) {
      expect((await patch(harness.app, `/v1/admin/users/${memberId}`, { complimentaryUntil: badDate }, adminToken)).status).toBe(400);
      expect((await get(harness.app, `/v1/admin/audit?since=${encodeURIComponent(badDate)}`, adminToken)).status).toBe(400);
    }
    for (const badLimit of ["0", "-5", "201", "1.5", "NaN", "1e2", ""]) {
      expect((await get(harness.app, `/v1/admin/audit?limit=${encodeURIComponent(badLimit)}`, adminToken)).status).toBe(400);
    }
    const badJson = await harness.app.request("/v1/billing/checkout", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${memberToken}` },
      body: "{bad",
    });
    expect(badJson.status).toBe(400);
  });

  it("ignores prototype-pollution keys and never pollutes Object.prototype", async () => {
    const rawSignup = JSON.stringify({
      email: "proto@example.com",
      password: "a-long-password",
      __proto__: { role: "admin", polluted: true },
      constructor: { prototype: { polluted: true } },
    });
    const signupRes = await harness.app.request("/v1/auth/signup", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: rawSignup,
    });
    expect(signupRes.status).toBe(201);
    const created = await json<SignedInResponse>(signupRes);
    expect(created.user.role).toBe("user");
    expect(({} as Record<string, unknown>).polluted).toBeUndefined();

    const emptyPatch = await harness.app.request(`/v1/admin/users/${memberId}`, {
      method: "PATCH",
      headers: { "content-type": "application/json", authorization: `Bearer ${adminToken}` },
      body: '{"__proto__":{"role":"admin"},"constructor":{"prototype":{"polluted":true}}}',
    });
    expect(emptyPatch.status).toBe(400);
    expect(({} as Record<string, unknown>).polluted).toBeUndefined();

    const badPlan = await harness.app.request("/v1/billing/checkout", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${memberToken}` },
      body: '{"__proto__":{"plan":"monthly"}}',
    });
    expect(badPlan.status).toBe(400);
    expect(({} as Record<string, unknown>).plan).toBeUndefined();
  });

  it("enforces CSRF header on browser-originated mutations across routes", async () => {
    const mutations: Array<{ method: string; path: string; token: string; body?: string }> = [
      { method: "POST", path: "/v1/auth/logout", token: memberToken },
      { method: "POST", path: "/v1/auth/password", token: memberToken, body: '{"currentPassword":"a-long-password","newPassword":"another-long-password"}' },
      { method: "POST", path: "/v1/billing/checkout", token: memberToken, body: '{"plan":"monthly"}' },
      { method: "POST", path: "/v1/billing/portal", token: memberToken },
      { method: "PATCH", path: `/v1/admin/users/${memberId}`, token: adminToken, body: '{"complimentaryUntil":null}' },
    ];
    for (const req of mutations) {
      const noHeaderOrigin = await harness.app.request(req.path, {
        method: req.method,
        headers: { authorization: `Bearer ${req.token}`, origin: "https://evil.example", "content-type": "application/json" },
        ...(req.body ? { body: req.body } : {}),
      });
      expect(noHeaderOrigin.status).toBe(403);

      const noHeaderCookie = await harness.app.request(req.path, {
        method: req.method,
        headers: { authorization: `Bearer ${req.token}`, cookie: "ic_access=1", "content-type": "application/json" },
        ...(req.body ? { body: req.body } : {}),
      });
      expect(noHeaderCookie.status).toBe(403);
    }

    const withHeader = await harness.app.request("/v1/billing/checkout", {
      method: "POST",
      headers: {
        authorization: `Bearer ${memberToken}`,
        origin: "https://app.example",
        "x-interviewcheck": "1",
        "content-type": "application/json",
      },
      body: '{"plan":"monthly"}',
    });
    expect(withHeader.status).toBe(200);
  });

  it("blocks revoked sessions, disabled accounts, and demoted admins", async () => {
    expect((await post(harness.app, "/v1/auth/logout", {}, memberToken)).status).toBe(204);
    expect((await get(harness.app, "/v1/me", memberToken)).status).toBe(401);
    expect((await post(harness.app, "/v1/billing/checkout", { plan: "monthly" }, memberToken)).status).toBe(401);

    const freshMember = await json<SignedInResponse>(
      await post(harness.app, "/v1/auth/login", { email: "member@example.com", password: "a-long-password" }),
    );
    expect((await patch(harness.app, `/v1/admin/users/${memberId}`, { disabled: true }, adminToken)).status).toBe(200);
    expect((await get(harness.app, "/v1/me", freshMember.token)).status).toBe(401);
    expect((await post(harness.app, "/v1/auth/login", { email: "member@example.com", password: "a-long-password" })).status).toBe(403);

    await patch(harness.app, `/v1/admin/users/${memberId}`, { disabled: false, role: "admin" }, adminToken);
    const secondAdmin = await json<SignedInResponse>(
      await post(harness.app, "/v1/auth/login", { email: "member@example.com", password: "a-long-password" }),
    );
    expect((await get(harness.app, "/v1/admin/audit", secondAdmin.token)).status).toBe(200);
    await patch(harness.app, `/v1/admin/users/${memberId}`, { role: "user" }, adminToken);
    expect((await get(harness.app, "/v1/admin/audit", secondAdmin.token)).status).toBe(401);
    const demotedLogin = await json<SignedInResponse>(
      await post(harness.app, "/v1/auth/login", { email: "member@example.com", password: "a-long-password" }),
    );
    expect((await get(harness.app, "/v1/admin/audit", demotedLogin.token)).status).toBe(403);
  });

  it("returns 429 with numeric Retry-After on rate-limited endpoints and neutralizes XSS on billing return", async () => {
    let billingRes!: Response;
    for (let i = 0; i < 21; i += 1) {
      billingRes = await post(harness.app, "/v1/billing/checkout", { plan: "monthly" }, memberToken);
    }
    expect(billingRes.status).toBe(429);
    expect(Number(billingRes.headers.get("retry-after"))).toBeGreaterThanOrEqual(1);

    let auditRes!: Response;
    for (let i = 0; i < 121; i += 1) {
      auditRes = await get(harness.app, "/v1/admin/audit", adminToken);
    }
    expect(auditRes.status).toBe(429);
    expect(Number(auditRes.headers.get("retry-after"))).toBeGreaterThanOrEqual(1);

    const xssReturn = await get(harness.app, "/v1/billing/return?status=%3Cscript%3Ealert(1)%3C/script%3E");
    expect(xssReturn.status).toBe(200);
    const html = await xssReturn.text();
    expect(html).not.toContain("<script>");
    expect(html).toContain("interviewcheck://billing/success");
  });
});
