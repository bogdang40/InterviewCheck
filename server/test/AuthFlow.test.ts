import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { SignedInResponse } from "../src/services/AuthService.js";
import type { AccessSnapshot } from "../src/services/EntitlementService.js";
import { buildHarness, get, json, post, type TestHarness } from "./support/TestContainer.js";

const DAY = 24 * 60 * 60 * 1000;

describe("auth flow over HTTP", () => {
  let harness: TestHarness;

  beforeEach(() => {
    harness = buildHarness();
  });

  afterEach(() => {
    harness.container.close();
  });

  it("signs up, returns a token, and /me works with it", async () => {
    const response = await post(harness.app, "/v1/auth/signup", { email: "Person@Example.com", password: "a-long-password" });
    expect(response.status).toBe(201);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = await json<SignedInResponse>(response);
    expect(body.token.startsWith("mm_")).toBe(true);
    expect(body.user.email).toBe("person@example.com");
    expect(body.user.role).toBe("user");
    expect(body.entitlement.active).toBe(false);

    const me = await get(harness.app, "/v1/me", body.token);
    expect(me.status).toBe(200);
    expect((await json<AccessSnapshot>(me)).user.id).toBe(body.user.id);
  });

  it("grants admin only to allow listed emails that present the bootstrap secret", async () => {
    const body = await json<SignedInResponse>(
      await post(harness.app, "/v1/auth/signup", { email: "owner@example.com", password: "a-long-password", adminSecret: "bootstrap-secret" }),
    );
    expect(body.user.role).toBe("admin");
    expect(body.entitlement).toMatchObject({ active: true, source: "admin" });
  });

  it("refuses admin without the secret, with a wrong secret, or for a non allow listed email", async () => {
    harness.container.close();
    harness = buildHarness({ ADMIN_EMAILS: ["a@example.com", "b@example.com", "c@example.com"] });
    const none = await json<SignedInResponse>(await post(harness.app, "/v1/auth/signup", { email: "a@example.com", password: "a-long-password" }));
    const wrong = await json<SignedInResponse>(await post(harness.app, "/v1/auth/signup", { email: "b@example.com", password: "a-long-password", adminSecret: "nope" }));
    const outsider = await json<SignedInResponse>(await post(harness.app, "/v1/auth/signup", { email: "z@example.com", password: "a-long-password", adminSecret: "bootstrap-secret" }));
    expect([none.user.role, wrong.user.role, outsider.user.role]).toEqual(["user", "user", "user"]);
  });

  it("turns a duplicate signup race into 409 instead of 500", async () => {
    const attempts = await Promise.all([
      post(harness.app, "/v1/auth/signup", { email: "race@example.com", password: "a-long-password" }),
      post(harness.app, "/v1/auth/signup", { email: "race@example.com", password: "a-long-password" }),
    ]);
    expect(attempts.map((r) => r.status).sort()).toEqual([201, 409]);
  });

  it("rolls back signup if session creation fails so the request can be retried", async () => {
    const database = harness.container.database;
    const form = { email: "retry@example.com", password: "a-long-password" };
    database.exec("CREATE TRIGGER reject_session BEFORE INSERT ON sessions BEGIN SELECT RAISE(ABORT, 'session failed'); END");
    expect((await post(harness.app, "/v1/auth/signup", form)).status).toBe(500);
    expect(harness.container.users.findByEmail(form.email)).toBeNull();
    expect(database.get("SELECT 1 FROM audit_log WHERE action = 'auth.signup'")).toBeUndefined();
    database.exec("DROP TRIGGER reject_session");
    expect((await post(harness.app, "/v1/auth/signup", form)).status).toBe(201);
  });

  it("rejects oversized bodies with 413", async () => {
    const huge = JSON.stringify({ email: "big@example.com", password: "x".repeat(300 * 1024) });
    const response = await harness.app.request("/v1/auth/signup", { method: "POST", headers: { "content-type": "application/json" }, body: huge });
    expect(response.status).toBe(413);
  });

  it("ignores client supplied forwarded headers unless TRUST_PROXY is on", async () => {
    let lastStatus = 0;
    for (let i = 0; i < 12; i += 1) {
      lastStatus = (
        await harness.app.request("/v1/auth/login", {
          method: "POST",
          headers: { "content-type": "application/json", "x-forwarded-for": `10.0.0.${i}, 203.0.113.9` },
          body: JSON.stringify({ email: "spray@example.com", password: "a-long-password" }),
        })
      ).status;
    }
    expect(lastStatus).toBe(429);
  });

  it("rejects duplicate emails, short passwords, and bad JSON", async () => {
    await post(harness.app, "/v1/auth/signup", { email: "dup@example.com", password: "a-long-password" });
    expect((await post(harness.app, "/v1/auth/signup", { email: "dup@example.com", password: "a-long-password" })).status).toBe(409);
    expect((await post(harness.app, "/v1/auth/signup", { email: "x@example.com", password: "short" })).status).toBe(400);
    const malformed = await harness.app.request("/v1/auth/signup", { method: "POST", body: "{nope" });
    expect(malformed.status).toBe(400);
  });

  it("logs in with correct credentials only", async () => {
    await post(harness.app, "/v1/auth/signup", { email: "login@example.com", password: "a-long-password" });
    expect((await post(harness.app, "/v1/auth/login", { email: "login@example.com", password: "wrong-password!" })).status).toBe(401);
    expect((await post(harness.app, "/v1/auth/login", { email: "nobody@example.com", password: "a-long-password" })).status).toBe(401);
    const ok = await post(harness.app, "/v1/auth/login", { email: "login@example.com", password: "a-long-password" });
    expect(ok.status).toBe(200);
  });

  it("logout revokes the token", async () => {
    const { token } = await json<SignedInResponse>(await post(harness.app, "/v1/auth/signup", { email: "bye@example.com", password: "a-long-password" }));
    expect((await post(harness.app, "/v1/auth/logout", {}, token)).status).toBe(204);
    expect((await get(harness.app, "/v1/me", token)).status).toBe(401);
  });

  it("expires sessions after the TTL and extends them when used", async () => {
    const { token } = await json<SignedInResponse>(await post(harness.app, "/v1/auth/signup", { email: "ttl@example.com", password: "a-long-password" }));
    harness.clock.now = new Date(harness.clock.now.getTime() + 20 * DAY);
    expect((await get(harness.app, "/v1/me", token)).status).toBe(200);
    harness.clock.now = new Date(harness.clock.now.getTime() + 25 * DAY);
    expect((await get(harness.app, "/v1/me", token)).status).toBe(200);
    harness.clock.now = new Date(harness.clock.now.getTime() + 31 * DAY);
    expect((await get(harness.app, "/v1/me", token)).status).toBe(401);
  });

  it("applies a trial when TRIAL_DAYS is set", async () => {
    harness.container.close();
    harness = buildHarness({ TRIAL_DAYS: 7 });
    const body = await json<SignedInResponse>(await post(harness.app, "/v1/auth/signup", { email: "trial@example.com", password: "a-long-password" }));
    expect(body.entitlement).toMatchObject({ active: true, source: "trial" });
    expect(new Date(body.entitlement.expiresAt ?? 0).getTime()).toBe(harness.clock.now.getTime() + 7 * DAY);
  });

  it("rate limits credential endpoints", async () => {
    let lastStatus = 0;
    for (let i = 0; i < 12; i += 1) {
      lastStatus = (await post(harness.app, "/v1/auth/login", { email: "spray@example.com", password: "a-long-password" })).status;
    }
    expect(lastStatus).toBe(429);
  });

  it("requires a bearer token on protected routes", async () => {
    expect((await get(harness.app, "/v1/me")).status).toBe(401);
    expect((await get(harness.app, "/v1/me", "mm_not_a_real_token_value_at_all_0000000000")).status).toBe(401);
  });
});
