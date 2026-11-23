import { randomBytes } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { AppConfig } from "../src/config/AppConfig.js";
import type { SignedInResponse } from "../src/services/AuthService.js";
import { TotpService, type TotpSetupView, type TotpVerifyView } from "../src/services/TotpService.js";
import { buildHarness, get, json, post, type TestHarness } from "./support/TestContainer.js";

const PASSWORD = "a-long-password";
const KEY_A = randomBytes(32).toString("base64");
const KEY_B = randomBytes(32).toString("base64");

describe("TOTP seed encryption key ring", () => {
  let directory: string;
  let harness: TestHarness | null = null;

  beforeEach(() => {
    directory = mkdtempSync(join(tmpdir(), "ic-totp-keys-"));
  });

  afterEach(() => {
    vi.restoreAllMocks();
    harness?.container.close();
    harness = null;
    rmSync(directory, { recursive: true, force: true });
  });

  function open(overrides: Partial<AppConfig>): TestHarness {
    const carriedClock = harness?.clock.now;
    harness?.container.close();
    harness = buildHarness({ DATABASE_PATH: join(directory, "access.sqlite"), ...overrides });
    if (carriedClock) harness.clock.now = carriedClock;
    return harness;
  }

  async function enrol(h: TestHarness): Promise<{ secret: string; backupCodes: string[]; userId: string }> {
    const member = await json<SignedInResponse>(await post(h.app, "/v1/auth/signup", { email: "member@example.com", password: PASSWORD }));
    const setup = await json<TotpSetupView>(await post(h.app, "/v1/auth/totp/setup", { currentPassword: PASSWORD }, member.token));
    const code = TotpService.generateTotpCode(setup.secret, h.clock.now.getTime());
    const verified = await json<TotpVerifyView>(await post(h.app, "/v1/auth/totp/verify", { code }, member.token));
    return { secret: setup.secret, backupCodes: verified.backupCodes, userId: member.user.id };
  }

  function storedSeed(h: TestHarness, userId: string): string {
    return h.container.database.get<{ secret_enc: string }>("SELECT secret_enc FROM user_totp WHERE user_id = ?", userId)!.secret_enc;
  }

  function login(h: TestHarness, totpCode: string): Promise<Response> {
    return post(h.app, "/v1/auth/login", { email: "member@example.com", password: PASSWORD, totpCode });
  }

  function nextStepCode(h: TestHarness, secret: string): string {
    h.clock.now = new Date(h.clock.now.getTime() + 30_000);
    return TotpService.generateTotpCode(secret, h.clock.now.getTime());
  }

  it("keeps TOTP login working after ADMIN_BOOTSTRAP_SECRET changes when a dedicated key is set", async () => {
    const first = open({ ADMIN_BOOTSTRAP_SECRET: "secret-one", TOTP_ENCRYPTION_KEY: KEY_A });
    const { secret, userId } = await enrol(first);
    expect(storedSeed(first, userId)).toMatch(/^v2:k1:/);

    const second = open({ ADMIN_BOOTSTRAP_SECRET: "secret-two", TOTP_ENCRYPTION_KEY: KEY_A });
    expect((await login(second, nextStepCode(second, secret))).status).toBe(200);
  });

  it("reads a legacy seed and re-encrypts it under the new key on the next successful login", async () => {
    const legacy = open({ ADMIN_BOOTSTRAP_SECRET: "secret-one" });
    const { secret, userId } = await enrol(legacy);
    const legacySeed = storedSeed(legacy, userId);
    expect(legacySeed).toMatch(/^v1:/);

    const upgraded = open({ ADMIN_BOOTSTRAP_SECRET: "secret-one", TOTP_ENCRYPTION_KEY: KEY_A });
    expect((await login(upgraded, nextStepCode(upgraded, secret))).status).toBe(200);
    expect(storedSeed(upgraded, userId)).toMatch(/^v2:k1:/);

    const rotated = open({ ADMIN_BOOTSTRAP_SECRET: "secret-two", TOTP_ENCRYPTION_KEY: KEY_A });
    expect((await login(rotated, nextStepCode(rotated, secret))).status).toBe(200);
  });

  it("re-encrypts legacy seeds at startup once a dedicated key is configured", async () => {
    const legacy = open({ ADMIN_BOOTSTRAP_SECRET: "secret-one" });
    const { userId } = await enrol(legacy);
    const upgraded = open({ ADMIN_BOOTSTRAP_SECRET: "secret-one", TOTP_ENCRYPTION_KEY: KEY_A });
    vi.spyOn(console, "log").mockImplementation(() => {});
    upgraded.container.prepare();
    expect(storedSeed(upgraded, userId)).toMatch(/^v2:k1:/);
  });

  it("rotates to a new primary key while a retired key still opens old seeds", async () => {
    const first = open({ TOTP_ENCRYPTION_KEY: KEY_A, TOTP_ENCRYPTION_KEY_ID: "k1" });
    const { secret, userId } = await enrol(first);
    const retired = new Map([["k1", Buffer.from(KEY_A, "base64")]]);
    const second = open({ TOTP_ENCRYPTION_KEY: KEY_B, TOTP_ENCRYPTION_KEY_ID: "k2", TOTP_ENCRYPTION_RETIRED_KEYS: retired });
    expect((await login(second, nextStepCode(second, secret))).status).toBe(200);
    expect(storedSeed(second, userId)).toMatch(/^v2:k2:/);
  });

  it("logs in with a backup code when the seed cannot be decrypted, and rejects TOTP codes with 401", async () => {
    const first = open({ ADMIN_BOOTSTRAP_SECRET: "secret-one" });
    const { secret, backupCodes } = await enrol(first);
    const errors = vi.spyOn(console, "error").mockImplementation(() => {});

    const broken = open({ ADMIN_BOOTSTRAP_SECRET: "secret-two" });
    const totpAttempt = await login(broken, nextStepCode(broken, secret));
    expect(totpAttempt.status).toBe(401);
    expect(await json(totpAttempt)).toMatchObject({ error: { code: "invalid_totp_code" } });

    expect((await login(broken, backupCodes[0]!)).status).toBe(200);
    const logged = errors.mock.calls.flat().join(" ");
    expect(logged).toContain("TOTP seed could not be decrypted (authentication_failed)");
    expect(logged).not.toContain("v1:");
    expect(logged).not.toContain(secret);
  });

  it("lets an admin reset a user's TOTP, revoking their sessions and recording an audit entry", async () => {
    const h = open({ TOTP_ENCRYPTION_KEY: KEY_A });
    const admin = await json<SignedInResponse>(
      await post(h.app, "/v1/auth/signup", { email: "owner@example.com", password: PASSWORD, adminSecret: "bootstrap-secret" }),
    );
    const { userId } = await enrol(h);

    expect((await post(h.app, `/v1/admin/users/${userId}/reset-totp`, {})).status).toBe(401);
    const memberToken = (await json<SignedInResponse>(await post(h.app, "/v1/auth/signup", { email: "other@example.com", password: PASSWORD }))).token;
    expect((await post(h.app, `/v1/admin/users/${userId}/reset-totp`, {}, memberToken)).status).toBe(403);
    expect((await post(h.app, "/v1/admin/users/00000000-0000-4000-8000-000000000000/reset-totp", {}, admin.token)).status).toBe(404);

    const activeBefore = h.container.sessions.listActiveForUser(userId, h.clock.now).length;
    expect(activeBefore).toBeGreaterThan(0);
    const reset = await post(h.app, `/v1/admin/users/${userId}/reset-totp`, {}, admin.token);
    expect(reset.status).toBe(200);
    expect(await json(reset)).toEqual({ userId, totpRemoved: true, revokedSessions: activeBefore });
    expect(h.container.sessions.listActiveForUser(userId, h.clock.now)).toHaveLength(0);
    expect(h.container.totp.isEnabled(userId)).toBe(false);

    const audit = h.container.audit.search({ action: "admin.totp_reset" }).entries;
    expect(audit).toHaveLength(1);
    expect(audit[0]).toMatchObject({ actorUserId: admin.user.id, targetUserId: userId, details: { totpRemoved: true } });

    expect((await post(h.app, "/v1/auth/login", { email: "member@example.com", password: PASSWORD })).status).toBe(200);
    expect((await get(h.app, "/v1/admin/audit/verify", admin.token)).status).toBe(200);
  });
});

