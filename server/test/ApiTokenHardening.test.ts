import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { SignedInResponse } from "../src/services/AuthService.js";
import type { CreatedApiTokenView } from "../src/services/SecurityService.js";
import { buildHarness, json, patch, post, type TestHarness } from "./support/TestContainer.js";

const PASSWORD = "a-long-password";

describe("API token hardening", () => {
  let harness: TestHarness;
  let adminToken: string;
  let memberToken: string;
  let memberId: string;

  beforeEach(async () => {
    harness = buildHarness();
    adminToken = (await json<SignedInResponse>(
      await post(harness.app, "/v1/auth/signup", { email: "owner@example.com", password: PASSWORD, adminSecret: "bootstrap-secret" }),
    )).token;
    const member = await json<SignedInResponse>(await post(harness.app, "/v1/auth/signup", { email: "member@example.com", password: PASSWORD }));
    memberToken = member.token;
    memberId = member.user.id;
  });

  afterEach(() => {
    harness.container.close();
  });

  async function mint(token: string, name = "Token"): Promise<Response> {
    return post(harness.app, "/v1/auth/tokens", { name, scopes: ["read:interviews"] }, token);
  }

  function isLive(rawToken: string): boolean {
    return harness.container.security.verifyApiToken(rawToken, "read:interviews") !== null;
  }

  it("rate limits token minting per user", async () => {
    for (let i = 0; i < 10; i += 1) expect((await mint(memberToken, `t${i}`)).status).toBe(201);
    const limited = await mint(memberToken, "one-too-many");
    expect(limited.status).toBe(429);
    expect(limited.headers.get("retry-after")).toMatch(/^\d+$/);
    expect((await mint(adminToken)).status).toBe(201);
  });

  it("caps active tokens per user and frees a slot when one is revoked", async () => {
    const created: CreatedApiTokenView[] = [];
    for (let i = 0; i < 25; i += 1) {
      if (i % 10 === 0) harness.container.apiTokenLimiter.clear();
      created.push(await json<CreatedApiTokenView>(await mint(memberToken, `t${i}`)));
    }
    harness.container.apiTokenLimiter.clear();
    const capped = await mint(memberToken, "over-cap");
    expect(capped.status).toBe(409);
    expect(await json(capped)).toMatchObject({ error: { code: "token_limit_reached" } });

    const revoke = await harness.app.request(`/v1/auth/tokens/${created[0]!.apiToken.id}`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${memberToken}` },
    });
    expect(revoke.status).toBe(200);
    expect((await mint(memberToken, "after-revoke")).status).toBe(201);
  });

  it("revokes a user's API tokens when they change their password", async () => {
    const { token } = await json<CreatedApiTokenView>(await mint(memberToken));
    expect(isLive(token)).toBe(true);
    const changed = await post(harness.app, "/v1/auth/password", { currentPassword: PASSWORD, newPassword: "another-long-password" }, memberToken);
    expect(changed.status).toBe(200);
    expect(isLive(token)).toBe(false);
  });

  it("revokes a user's API tokens when an admin disables the account, and they stay revoked after re-enabling", async () => {
    const { token } = await json<CreatedApiTokenView>(await mint(memberToken));
    expect((await patch(harness.app, `/v1/admin/users/${memberId}`, { disabled: true }, adminToken)).status).toBe(200);
    expect((await patch(harness.app, `/v1/admin/users/${memberId}`, { disabled: false }, adminToken)).status).toBe(200);
    expect(isLive(token)).toBe(false);
    const revokedAt = harness.container.database.get<{ revoked_at: number | null }>("SELECT revoked_at FROM api_tokens WHERE user_id = ?", memberId);
    expect(revokedAt?.revoked_at).not.toBeNull();
  });
});
