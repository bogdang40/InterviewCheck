import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { AccessMetricsSnapshot } from "../src/http/routes/MetricsRoutes.js";
import type { SignedInResponse } from "../src/services/AuthService.js";
import { buildHarness, get, json, post, type TestHarness } from "./support/TestContainer.js";

describe("M16-W1 Node /v1/admin/metrics observability", () => {
  let harness: TestHarness;
  let adminToken: string;
  let memberToken: string;

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
  });

  afterEach(() => {
    harness.container.close();
  });

  it("enforces admin authentication and query validation", async () => {
    expect((await get(harness.app, "/v1/admin/metrics")).status).toBe(401);
    expect((await get(harness.app, "/v1/admin/metrics", memberToken)).status).toBe(403);
    expect((await get(harness.app, "/v1/admin/metrics?format=xml", adminToken)).status).toBe(400);
  });

  it("returns accurate JSON metrics and updates counts when sessions or tokens change", async () => {
    const tokenRes = await post(
      harness.app,
      "/v1/auth/tokens",
      { name: "Scraper", scopes: ["read:telemetry"], ttlDays: 7 },
      memberToken,
    );
    expect(tokenRes.status).toBe(201);

    const res1 = await get(harness.app, "/v1/admin/metrics?format=json", adminToken);
    expect(res1.status).toBe(200);
    expect(res1.headers.get("cache-control")).toBe("no-store");
    const snap1 = await json<AccessMetricsSnapshot>(res1);
    expect(snap1.users_total).toBe(2);
    expect(snap1.active_sessions_total).toBe(2);
    expect(snap1.active_api_tokens_total).toBe(1);
    expect(snap1.audit_log_total).toBeGreaterThanOrEqual(3);
    expect(snap1.rate_limit_buckets_total).toBeGreaterThanOrEqual(1);
    expect(snap1.rate_limit_buckets["memory:adminRead"]).toBeGreaterThanOrEqual(1);

    // Logout member session and advance clock past 7-day token TTL (while admin session still valid under 30d TTL)
    await post(harness.app, "/v1/auth/logout", {}, memberToken);
    harness.clock.now = new Date(harness.clock.now.getTime() + 8 * 86_400_000);
    const snap2 = await json<AccessMetricsSnapshot>(await get(harness.app, "/v1/admin/metrics?format=json", adminToken));
    expect(snap2.active_sessions_total).toBe(1);
    expect(snap2.active_api_tokens_total).toBe(0);
  });

  it("renders Prometheus text format and never leaks PII or secrets", async () => {
    const created = await json<{ token: string }>(
      await post(harness.app, "/v1/auth/tokens", { name: "CI", scopes: ["read:interviews"] }, memberToken),
    );
    await harness.app.request("/v1/auth/login", {
      method: "POST",
      headers: { "content-type": "application/json", "fly-client-ip": "2001:db8:abcd:1::42" },
      body: JSON.stringify({ email: "locked-pii@example.com", password: "wrong-password-123" }),
    });
    harness.container.database.run(
      "INSERT INTO login_email_windows (email, start, hits) VALUES (?, ?, ?)",
      "locked-pii@example.com",
      harness.clock.now.getTime(),
      4,
    );

    const promRes = await get(harness.app, "/v1/admin/metrics", adminToken);
    expect(promRes.status).toBe(200);
    expect(promRes.headers.get("content-type")).toBe("text/plain; version=0.0.4; charset=utf-8");
    expect(promRes.headers.get("cache-control")).toBe("no-store");
    const promText = await promRes.text();
    expect(promText).toContain("ic_access_users_total 2");
    expect(promText).toContain("ic_access_active_sessions_total 2");
    expect(promText).toContain("ic_access_active_api_tokens_total 1");
    expect(promText).toContain("ic_access_audit_log_total ");
    expect(promText).toContain("ic_access_rate_limit_buckets_total ");
    expect(promText).toContain('ic_access_rate_limit_buckets{source="login_email_windows",limiter="credential"} 1');

    const jsonText = await (await get(harness.app, "/v1/admin/metrics?format=json", adminToken)).text();
    for (const payload of [promText, jsonText]) {
      for (const secret of [
        "owner@example.com",
        "member@example.com",
        "locked-pii@example.com",
        "2001:db8:abcd",
        created.token,
        adminToken,
        memberToken,
      ]) {
        expect(payload).not.toContain(secret);
      }
    }
  });
});
