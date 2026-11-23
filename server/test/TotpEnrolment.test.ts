import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { SignedInResponse } from "../src/services/AuthService.js";
import { TotpService, type TotpSetupView } from "../src/services/TotpService.js";
import { buildHarness, get, json, post, type TestHarness } from "./support/TestContainer.js";

const PASSWORD = "a-long-password";

describe("TOTP enrolment requires the password and signs out other devices", () => {
  let harness: TestHarness;
  let token: string;
  let userId: string;

  beforeEach(async () => {
    harness = buildHarness();
    const member = await json<SignedInResponse>(await post(harness.app, "/v1/auth/signup", { email: "member@example.com", password: PASSWORD }));
    token = member.token;
    userId = member.user.id;
  });

  afterEach(() => {
    harness.container.close();
  });

  it("refuses to begin setup without the current password", async () => {
    const missing = await post(harness.app, "/v1/auth/totp/setup", {}, token);
    expect(missing.status).toBe(400);
    expect(await json(missing)).toMatchObject({ error: { code: "validation_failed" } });

    const wrong = await post(harness.app, "/v1/auth/totp/setup", { currentPassword: "wrong-long-password" }, token);
    expect(wrong.status).toBe(401);
    expect(await json(wrong)).toMatchObject({ error: { code: "invalid_credentials" } });
    expect(harness.container.database.get("SELECT 1 FROM user_totp WHERE user_id = ?", userId)).toBeUndefined();

    expect((await post(harness.app, "/v1/auth/totp/setup", { currentPassword: PASSWORD }, token)).status).toBe(200);
  });

  it("revokes every other session when TOTP becomes enabled and keeps the current one", async () => {
    const other = await json<SignedInResponse>(await post(harness.app, "/v1/auth/login", { email: "member@example.com", password: PASSWORD }));
    const setup = await json<TotpSetupView>(await post(harness.app, "/v1/auth/totp/setup", { currentPassword: PASSWORD }, token));
    const code = TotpService.generateTotpCode(setup.secret, harness.clock.now.getTime());
    expect((await post(harness.app, "/v1/auth/totp/verify", { code }, token)).status).toBe(200);

    expect((await get(harness.app, "/v1/me", token)).status).toBe(200);
    expect((await get(harness.app, "/v1/me", other.token)).status).toBe(401);
    const audit = harness.container.audit.search({ action: "auth.totp_enabled" }).entries;
    expect(audit[0]?.details).toEqual({ revokedSessions: 1 });
  });
});
