import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { AdminStats, AdminUserView } from "../src/services/AdminService.js";
import type { SignedInResponse } from "../src/services/AuthService.js";
import type { AccessSnapshot } from "../src/services/EntitlementService.js";
import { buildHarness, get, json, patch, post, type TestHarness } from "./support/TestContainer.js";

describe("admin API", () => {
  let harness: TestHarness;
  let adminToken: string;
  let adminId: string;
  let memberToken: string;
  let memberId: string;

  beforeEach(async () => {
    harness = buildHarness();
    const admin = await json<SignedInResponse>(
      await post(harness.app, "/v1/auth/signup", { email: "owner@example.com", password: "a-long-password", adminSecret: "bootstrap-secret" }),
    );
    adminToken = admin.token;
    adminId = admin.user.id;
    const member = await json<SignedInResponse>(await post(harness.app, "/v1/auth/signup", { email: "member@example.com", password: "a-long-password" }));
    memberToken = member.token;
    memberId = member.user.id;
  });

  afterEach(() => {
    harness.container.close();
  });

  it("forbids non admins", async () => {
    expect((await get(harness.app, "/v1/admin/users", memberToken)).status).toBe(403);
    expect((await get(harness.app, "/v1/admin/stats")).status).toBe(401);
  });

  it("lists users with entitlement and supports search", async () => {
    harness.container.subscriptions.upsert({
      id: "sub_member", userId: memberId, status: "active", priceId: "price_monthly", plan: "monthly",
      currentPeriodEnd: new Date(harness.clock.now.getTime() + 86400000), cancelAtPeriodEnd: false,
    }, harness.clock.now);
    const subscriptionLookup = vi.spyOn(harness.container.subscriptions, "currentForUser");
    const all = await json<{ users: AdminUserView[]; nextCursor: string | null }>(await get(harness.app, "/v1/admin/users", adminToken));
    expect(all.users.map((view) => view.user.email).sort()).toEqual(["member@example.com", "owner@example.com"]);
    expect(subscriptionLookup).toHaveBeenCalledTimes(all.users.length);
    const member = all.users.find((view) => view.user.id === memberId);
    expect(member?.subscription).toMatchObject({ id: "sub_member", status: "active", plan: "monthly" });
    expect(member?.entitlement).toMatchObject({ active: true, source: "subscription", plan: "monthly" });
    const filtered = await json<{ users: AdminUserView[] }>(await get(harness.app, "/v1/admin/users?q=member", adminToken));
    expect(filtered.users).toHaveLength(1);
    expect(filtered.users[0]).toEqual(member);
  });

  it("paginates with a cursor", async () => {
    for (let i = 0; i < 3; i += 1) {
      harness.clock.now = new Date(harness.clock.now.getTime() + 1000);
      await post(harness.app, "/v1/auth/signup", { email: `bulk${i}@example.com`, password: "a-long-password" });
    }
    const first = await json<{ users: AdminUserView[]; nextCursor: string | null }>(await get(harness.app, "/v1/admin/users?limit=2", adminToken));
    expect(first.users).toHaveLength(2);
    expect(first.nextCursor).not.toBeNull();
    const second = await json<{ users: AdminUserView[]; nextCursor: string | null }>(
      await get(harness.app, `/v1/admin/users?limit=2&cursor=${encodeURIComponent(first.nextCursor ?? "")}`, adminToken),
    );
    const seen = new Set([...first.users, ...second.users].map((view) => view.user.id));
    expect(seen.size).toBe(4);
  });

  it("grants complimentary access that unlocks the member", async () => {
    const until = new Date(harness.clock.now.getTime() + 30 * 24 * 3600 * 1000).toISOString();
    const response = await patch(harness.app, `/v1/admin/users/${memberId}`, { complimentaryUntil: until }, adminToken);
    expect(response.status).toBe(200);
    const view = await json<AdminUserView>(response);
    expect(view.entitlement).toMatchObject({ active: true, source: "complimentary" });
    const me = await json<AccessSnapshot>(await get(harness.app, "/v1/me", memberToken));
    expect(me.entitlement.active).toBe(true);

    const cleared = await json<AdminUserView>(await patch(harness.app, `/v1/admin/users/${memberId}`, { complimentaryUntil: null }, adminToken));
    expect(cleared.entitlement.active).toBe(false);
  });

  it("promotes and demotes roles, revokes sessions on role change, and never removes the last admin", async () => {
    const promoted = await json<AdminUserView>(await patch(harness.app, `/v1/admin/users/${memberId}`, { role: "admin" }, adminToken));
    expect(promoted.user.role).toBe("admin");
    expect((await get(harness.app, "/v1/me", memberToken)).status).toBe(401);
    const reauthed = await json<SignedInResponse>(await post(harness.app, "/v1/auth/login", { email: "member@example.com", password: "a-long-password" }));
    const promotedToken = reauthed.token;

    expect((await patch(harness.app, `/v1/admin/users/${adminId}`, { role: "user" }, adminToken)).status).toBe(200);
    expect((await get(harness.app, "/v1/me", adminToken)).status).toBe(401);
    expect((await patch(harness.app, `/v1/admin/users/${memberId}`, { role: "user" }, promotedToken)).status).toBe(409);
  });

  it("lets a disabled admin be demoted even when they are the only other admin", async () => {
    const second = await json<SignedInResponse>(
      await post(harness.app, "/v1/auth/signup", { email: "second@example.com", password: "a-long-password" }),
    );
    expect((await patch(harness.app, `/v1/admin/users/${second.user.id}`, { role: "admin" }, adminToken)).status).toBe(200);
    expect((await patch(harness.app, `/v1/admin/users/${second.user.id}`, { disabled: true }, adminToken)).status).toBe(200);
    // Only the owner is an active admin now; tidying the disabled admin's
    // role must not be refused as removing the last admin.
    expect((await patch(harness.app, `/v1/admin/users/${second.user.id}`, { role: "user" }, adminToken)).status).toBe(200);
    // The owner really is the last active admin.
    expect((await patch(harness.app, `/v1/admin/users/${adminId}`, { role: "user" }, adminToken)).status).toBe(409);
  });

  it("disabling a user revokes their sessions and blocks login", async () => {
    expect((await patch(harness.app, `/v1/admin/users/${memberId}`, { disabled: true }, adminToken)).status).toBe(200);
    expect((await get(harness.app, "/v1/me", memberToken)).status).toBe(401);
    expect((await post(harness.app, "/v1/auth/login", { email: "member@example.com", password: "a-long-password" })).status).toBe(403);
    expect((await patch(harness.app, `/v1/admin/users/${adminId}`, { disabled: true }, adminToken)).status).toBe(409);
  });

  it("rolls back the account change and session revocation if the audit write fails", async () => {
    const database = harness.container.database;
    database.exec(`CREATE TRIGGER reject_audit BEFORE INSERT ON audit_log
      WHEN NEW.action = 'admin.update_user' BEGIN SELECT RAISE(ABORT, 'audit failed'); END`);
    expect((await patch(harness.app, `/v1/admin/users/${memberId}`, { disabled: true }, adminToken)).status).toBe(500);
    expect(harness.container.users.findById(memberId)?.disabled).toBe(false);
    expect((await get(harness.app, "/v1/me", memberToken)).status).toBe(200);
  });

  it("reports stats and an audit trail", async () => {
    const stats = await json<AdminStats>(await get(harness.app, "/v1/admin/stats", adminToken));
    expect(stats).toEqual({ totalUsers: 2, admins: 1, liveSubscriptions: 0 });
    const audit = await json<{ entries: Array<{ action: string }> }>(await get(harness.app, "/v1/admin/audit", adminToken));
    expect(audit.entries.map((entry) => entry.action)).toContain("auth.signup");
  });

  it("validates UUID path params, query limits, and patch bodies", async () => {
    expect((await patch(harness.app, `/v1/admin/users/${memberId}`, {}, adminToken)).status).toBe(400);
    expect((await patch(harness.app, `/v1/admin/users/${memberId}`, { role: "owner" }, adminToken)).status).toBe(400);
    expect((await patch(harness.app, "/v1/admin/users/missing", { role: "admin" }, adminToken)).status).toBe(400);
    expect((await get(harness.app, "/v1/admin/users/missing", adminToken)).status).toBe(400);
    expect((await get(harness.app, "/v1/admin/users/00000000-0000-4000-8000-000000000000", adminToken)).status).toBe(404);
    expect((await patch(harness.app, "/v1/admin/users/00000000-0000-4000-8000-000000000000", { role: "admin" }, adminToken)).status).toBe(404);
    for (const bad of ["0", "-1", "201", "1.5", "abc", "", "1e2"]) {
      expect((await get(harness.app, `/v1/admin/audit?limit=${encodeURIComponent(bad)}`, adminToken)).status).toBe(400);
      expect((await get(harness.app, `/v1/admin/users?limit=${encodeURIComponent(bad)}`, adminToken)).status).toBe(400);
    }
    expect((await get(harness.app, "/v1/admin/audit?limit=1", adminToken)).status).toBe(200);
    expect((await get(harness.app, "/v1/admin/audit?limit=200", adminToken)).status).toBe(200);
  });

  it("enforces security headers, CSRF on browser /v1 mutations, and rate limits", async () => {
    const health = await harness.app.request("/health");
    expect(health.headers.get("x-frame-options")).toBe("DENY");
    expect(health.headers.get("x-content-type-options")).toBe("nosniff");
    expect(health.headers.get("referrer-policy")).toBe("no-referrer");
    expect(health.headers.get("permissions-policy")).toContain("camera=()");
    expect(health.headers.get("content-security-policy")).toContain("default-src 'none'");

    const billingReturn = await harness.app.request("/v1/billing/return?status=success");
    expect(billingReturn.headers.get("content-security-policy")).toContain("style-src 'sha256-");

    const browserCsrfBlocked = await harness.app.request(`/v1/admin/users/${memberId}`, {
      method: "PATCH",
      headers: { authorization: `Bearer ${adminToken}`, "content-type": "application/json", origin: "https://evil.example" },
      body: JSON.stringify({ role: "admin" }),
    });
    expect(browserCsrfBlocked.status).toBe(403);

    const cookieCsrfBlocked = await harness.app.request("/v1/auth/logout", {
      method: "POST",
      headers: { authorization: `Bearer ${memberToken}`, cookie: "ic_access=abc" },
    });
    expect(cookieCsrfBlocked.status).toBe(403);

    const browserCsrfAllowed = await harness.app.request(`/v1/admin/users/${memberId}`, {
      method: "PATCH",
      headers: { authorization: `Bearer ${adminToken}`, "content-type": "application/json", origin: "https://app.example", "x-interviewcheck": "1" },
      body: JSON.stringify({ complimentaryUntil: null }),
    });
    expect(browserCsrfAllowed.status).toBe(200);

    let lastStatus = 0;
    for (let i = 0; i < 42; i += 1) {
      lastStatus = (await patch(harness.app, `/v1/admin/users/${memberId}`, { complimentaryUntil: null }, adminToken)).status;
    }
    expect(lastStatus).toBe(429);
  });

  it("treats LIKE wildcards in search as literal characters", async () => {
    const percent = await json<{ users: AdminUserView[] }>(await get(harness.app, "/v1/admin/users?q=%25", adminToken));
    expect(percent.users).toHaveLength(0);
    const underscore = await json<{ users: AdminUserView[] }>(await get(harness.app, "/v1/admin/users?q=m_mber", adminToken));
    expect(underscore.users).toHaveLength(0);
    const plain = await json<{ users: AdminUserView[] }>(await get(harness.app, "/v1/admin/users?q=member", adminToken));
    expect(plain.users).toHaveLength(1);
  });
});
