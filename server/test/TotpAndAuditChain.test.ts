import { createHash } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { AuditChainVerification } from "../src/repositories/AuditLogRepository.js";
import type { SignedInResponse } from "../src/services/AuthService.js";
import type { CreatedApiTokenView } from "../src/services/SecurityService.js";
import { TotpService, type TotpSetupView, type TotpStatusView, type TotpVerifyView } from "../src/services/TotpService.js";
import { buildHarness, get, json, post, type TestHarness } from "./support/TestContainer.js";

describe("M18 TOTP 2FA and audit hash chain", () => {
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
        adminSecret: "bootstrap-secret",
      }),
    );
    adminToken = admin.token;
    const member = await json<SignedInResponse>(
      await post(harness.app, "/v1/auth/signup", {
        email: "member@example.com",
        password: "a-long-password",
      }),
    );
    memberToken = member.token;
    memberId = member.user.id;
  });

  afterEach(() => {
    harness.container.close();
  });

  it("matches RFC 6238 HMAC-SHA1 test vectors and enforces [-1, 0, +1] time window", () => {
    // RFC 6238 Appendix B SHA1 test secret: ASCII "12345678901234567890"
    const rfcSecret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";
    expect(TotpService.generateTotpCode(rfcSecret, 59_000)).toBe("287082");
    expect(TotpService.generateTotpCode(rfcSecret, 1_111_111_109_000)).toBe("081804");
    expect(TotpService.generateTotpCode(rfcSecret, 1_234_567_890_000)).toBe("005924");

    const nowMs = 1_700_000_010_000;
    const prevCode = TotpService.generateTotpCode(rfcSecret, nowMs - 30_000);
    const currCode = TotpService.generateTotpCode(rfcSecret, nowMs);
    const nextCode = TotpService.generateTotpCode(rfcSecret, nowMs + 30_000);
    const tooOld = TotpService.generateTotpCode(rfcSecret, nowMs - 60_000);
    const tooNew = TotpService.generateTotpCode(rfcSecret, nowMs + 60_000);

    expect(TotpService.verifyTotpCode(rfcSecret, prevCode, nowMs)).toBe(true);
    expect(TotpService.verifyTotpCode(rfcSecret, currCode, nowMs)).toBe(true);
    expect(TotpService.verifyTotpCode(rfcSecret, nextCode, nowMs)).toBe(true);
    expect(TotpService.verifyTotpCode(rfcSecret, tooOld, nowMs)).toBe(false);
    expect(TotpService.verifyTotpCode(rfcSecret, tooNew, nowMs)).toBe(false);
    expect(TotpService.verifyTotpCode(rfcSecret, "12345", nowMs)).toBe(false);
    const baseStep = Math.floor(nowMs / 1000 / 30);
    expect(TotpService.matchTotpStep(rfcSecret, prevCode, nowMs)).toBe(baseStep - 1);
    expect(TotpService.matchTotpStep(rfcSecret, currCode, nowMs)).toBe(baseStep);
    expect(TotpService.matchTotpStep(rfcSecret, nextCode, nowMs)).toBe(baseStep + 1);
    expect(TotpService.matchTotpStep(rfcSecret, tooOld, nowMs)).toBeNull();
  });

  it("enforces auth, encrypts secrets with user_id AAD, and completes setup/verify/regenerate/disable lifecycle", async () => {
    expect((await get(harness.app, "/v1/auth/totp/status")).status).toBe(401);
    expect((await post(harness.app, "/v1/auth/totp/setup", {})).status).toBe(401);

    const apiTokenRes = await json<CreatedApiTokenView>(
      await post(harness.app, "/v1/auth/tokens", { name: "Token", scopes: ["read:interviews"] }, memberToken),
    );
    expect((await get(harness.app, "/v1/auth/totp/status", apiTokenRes.token)).status).toBe(401);

    const initialStatus = await json<TotpStatusView>(await get(harness.app, "/v1/auth/totp/status", memberToken));
    expect(initialStatus).toEqual({ enabled: false, verifiedAt: null, remainingBackupCodes: 0 });
    expect((await post(harness.app, "/v1/auth/totp/verify", { code: "123456" }, memberToken)).status).toBe(400);

    const setup = await json<TotpSetupView>(await post(harness.app, "/v1/auth/totp/setup", {}, memberToken));
    expect(setup.issuer).toBe("InterviewCheck");
    expect(setup.secret).toMatch(/^[A-Z2-7]{32}$/);
    expect(setup.otpauthUri).toContain("otpauth://totp/InterviewCheck:member%40example.com");
    expect(setup.otpauthUri).toContain(`secret=${setup.secret}`);

    const encRow = harness.container.database.get<{ secret_enc: string; enabled: number }>(
      "SELECT secret_enc, enabled FROM user_totp WHERE user_id = ?",
      memberId,
    );
    expect(encRow?.enabled).toBe(0);
    expect(encRow?.secret_enc.startsWith("v1:")).toBe(true);
    expect(encRow?.secret_enc).not.toContain(setup.secret);

    expect((await post(harness.app, "/v1/auth/totp/verify", { code: "000000" }, memberToken)).status).toBe(400);

    const validCode = TotpService.generateTotpCode(setup.secret, harness.clock.now.getTime());
    const verified = await json<TotpVerifyView>(await post(harness.app, "/v1/auth/totp/verify", { code: validCode }, memberToken));
    expect(verified.enabled).toBe(true);
    expect(verified.verifiedAt).toBe(harness.clock.now.toISOString());
    expect(verified.backupCodes).toHaveLength(8);
    expect(new Set(verified.backupCodes).size).toBe(8);
    for (const code of verified.backupCodes) {
      expect(code).toMatch(/^[A-Z2-9]{4}-[A-Z2-9]{4}$/);
      const hash = createHash("sha256").update(code, "utf8").digest("hex");
      const dbCode = harness.container.database.get<{ id: string }>(
        "SELECT id FROM user_backup_codes WHERE user_id = ? AND code_hash = ?",
        memberId,
        hash,
      );
      expect(dbCode).toBeDefined();
    }

    expect((await post(harness.app, "/v1/auth/totp/setup", {}, memberToken)).status).toBe(409);

    const statusAfter = await json<TotpStatusView>(await get(harness.app, "/v1/auth/totp/status", memberToken));
    expect(statusAfter).toEqual({ enabled: true, verifiedAt: harness.clock.now.toISOString(), remainingBackupCodes: 8 });

    // AAD mismatch check: copying member's encrypted secret to admin must fail decryption.
    const activeEnc = harness.container.database.get<{ secret_enc: string }>(
      "SELECT secret_enc FROM user_totp WHERE user_id = ?",
      memberId,
    )!.secret_enc;
    const adminId = harness.container.users.findByEmail("owner@example.com")!.id;
    harness.container.database.run(
      "INSERT INTO user_totp (user_id, secret_enc, enabled, verified_at, created_at) VALUES (?, ?, 1, ?, ?)",
      adminId,
      activeEnc,
      harness.clock.now.getTime(),
      harness.clock.now.getTime(),
    );
    const decryptErrors = vi.spyOn(console, "error").mockImplementation(() => {});
    expect(harness.container.totp.verifyLoginFactor(adminId, validCode, harness.clock.now)).toBeNull();
    expect(decryptErrors).toHaveBeenCalledWith(expect.stringContaining("TOTP seed could not be decrypted (authentication_failed)"));
    decryptErrors.mockRestore();
    harness.container.database.run("DELETE FROM user_totp WHERE user_id = ?", adminId);

    // Regenerate backup codes requires valid next-step TOTP
    expect((await post(harness.app, "/v1/auth/totp/backup-codes/regenerate", { code: "000000" }, memberToken)).status).toBe(401);
    harness.clock.now = new Date(harness.clock.now.getTime() + 30_000);
    const regenCode = TotpService.generateTotpCode(setup.secret, harness.clock.now.getTime());
    const regen = await json<{ backupCodes: string[] }>(
      await post(harness.app, "/v1/auth/totp/backup-codes/regenerate", { code: regenCode }, memberToken),
    );
    expect(regen.backupCodes).toHaveLength(8);
    expect(regen.backupCodes[0]).not.toBe(verified.backupCodes[0]);

    // Disable requires valid password + TOTP or backup code
    expect((await post(harness.app, "/v1/auth/totp/disable", { currentPassword: "wrong-password!", code: regenCode }, memberToken)).status).toBe(401);
    expect((await post(harness.app, "/v1/auth/totp/disable", { currentPassword: "a-long-password", code: verified.backupCodes[0] }, memberToken)).status).toBe(401);
    const disabled = await post(harness.app, "/v1/auth/totp/disable", { currentPassword: "a-long-password", code: regen.backupCodes[0] }, memberToken);
    expect(disabled.status).toBe(200);
    expect(await json(disabled)).toEqual({ enabled: false });
    expect(await json<TotpStatusView>(await get(harness.app, "/v1/auth/totp/status", memberToken))).toEqual({
      enabled: false,
      verifiedAt: null,
      remainingBackupCodes: 0,
    });
  });

  it("requires TOTP on login, redeems single-use backup codes transactionally, and locks out repeated failures", async () => {
    const setup = await json<TotpSetupView>(await post(harness.app, "/v1/auth/totp/setup", {}, memberToken));
    const code = TotpService.generateTotpCode(setup.secret, harness.clock.now.getTime());
    const verified = await json<TotpVerifyView>(await post(harness.app, "/v1/auth/totp/verify", { code }, memberToken));

    const missing = await post(harness.app, "/v1/auth/login", { email: "member@example.com", password: "a-long-password" });
    expect(missing.status).toBe(401);
    expect(missing.headers.get("x-interviewcheck-totp")).toBe("required");
    expect(await json(missing)).toMatchObject({ error: { code: "totp_required" } });

    const badTotp = await post(harness.app, "/v1/auth/login", {
      email: "member@example.com",
      password: "a-long-password",
      totpCode: "000000",
    });
    expect(badTotp.status).toBe(401);
    expect(harness.container.database.get<{ hits: number }>("SELECT hits FROM login_email_windows WHERE email = ?", "member@example.com")?.hits).toBe(1);

    // Valid TOTP login on next step succeeds and resets email lockout counter
    harness.clock.now = new Date(harness.clock.now.getTime() + 30_000);
    const loginCode = TotpService.generateTotpCode(setup.secret, harness.clock.now.getTime());
    const okLogin = await post(harness.app, "/v1/auth/login", {
      email: "member@example.com",
      password: "a-long-password",
      totpCode: loginCode,
    });
    expect(okLogin.status).toBe(200);
    expect((await json<SignedInResponse>(okLogin)).token.startsWith("mm_")).toBe(true);
    expect(harness.container.database.get("SELECT 1 FROM login_email_windows WHERE email = ?", "member@example.com")).toBeUndefined();

    // Backup code rollback if session insert fails
    const backup = verified.backupCodes[0]!;
    harness.container.database.exec("CREATE TRIGGER abort_session BEFORE INSERT ON sessions BEGIN SELECT RAISE(ABORT, 'db failure'); END");
    const failedTx = await post(harness.app, "/v1/auth/login", {
      email: "member@example.com",
      password: "a-long-password",
      totpCode: backup,
    });
    expect(failedTx.status).toBe(500);
    harness.container.database.exec("DROP TRIGGER abort_session");
    expect((await json<TotpStatusView>(await get(harness.app, "/v1/auth/totp/status", memberToken))).remainingBackupCodes).toBe(8);

    // Redeem backup code (case/hyphen insensitive), then confirm reuse fails
    const backupOk = await post(harness.app, "/v1/auth/login", {
      email: "member@example.com",
      password: "a-long-password",
      totpCode: backup.replace("-", "").toLowerCase(),
    });
    expect(backupOk.status).toBe(200);
    expect((await json<TotpStatusView>(await get(harness.app, "/v1/auth/totp/status", memberToken))).remainingBackupCodes).toBe(7);

    const backupReuse = await post(harness.app, "/v1/auth/login", {
      email: "member@example.com",
      password: "a-long-password",
      totpCode: backup,
    });
    expect(backupReuse.status).toBe(401);

    // Email lockout after 10 invalid TOTP attempts across different client IPs
    for (let i = 0; i < 9; i += 1) {
      const attempt = await harness.app.request("/v1/auth/login", {
        method: "POST",
        headers: { "content-type": "application/json", "fly-client-ip": `198.51.100.${i + 1}` },
        body: JSON.stringify({ email: "member@example.com", password: "a-long-password", totpCode: "000000" }),
      });
      expect(attempt.status).toBe(401);
    }
    const locked = await harness.app.request("/v1/auth/login", {
      method: "POST",
      headers: { "content-type": "application/json", "fly-client-ip": "198.51.100.99" },
      body: JSON.stringify({ email: "member@example.com", password: "a-long-password", totpCode: loginCode }),
    });
    expect(locked.status).toBe(429);
  });

  it("rejects same-step TOTP replays across verify, login, regenerate, and disable", async () => {
    const setup = await json<TotpSetupView>(await post(harness.app, "/v1/auth/totp/setup", {}, memberToken));
    const step0Code = TotpService.generateTotpCode(setup.secret, harness.clock.now.getTime());
    expect((await post(harness.app, "/v1/auth/totp/verify", { code: step0Code }, memberToken)).status).toBe(200);

    // verify -> login, verify -> regenerate, verify -> disable all rejected in same step
    expect((await post(harness.app, "/v1/auth/login", { email: "member@example.com", password: "a-long-password", totpCode: step0Code })).status).toBe(401);
    expect((await post(harness.app, "/v1/auth/totp/backup-codes/regenerate", { code: step0Code }, memberToken)).status).toBe(401);
    expect((await post(harness.app, "/v1/auth/totp/disable", { currentPassword: "a-long-password", code: step0Code }, memberToken)).status).toBe(401);

    // Advance one step: login -> login rejected in same step, then next step disables cleanly
    harness.clock.now = new Date(harness.clock.now.getTime() + 30_000);
    const step1Code = TotpService.generateTotpCode(setup.secret, harness.clock.now.getTime());
    expect((await post(harness.app, "/v1/auth/login", { email: "member@example.com", password: "a-long-password", totpCode: step1Code })).status).toBe(200);
    expect((await post(harness.app, "/v1/auth/login", { email: "member@example.com", password: "a-long-password", totpCode: step1Code })).status).toBe(401);

    harness.clock.now = new Date(harness.clock.now.getTime() + 30_000);
    const step2Code = TotpService.generateTotpCode(setup.secret, harness.clock.now.getTime());
    expect((await post(harness.app, "/v1/auth/totp/disable", { currentPassword: "a-long-password", code: step2Code }, memberToken)).status).toBe(200);
  });

  it("handles step 0 (nowMs < 30_000) in unit helpers and HTTP verify, replay, and login", async () => {
    const rfcSecret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";
    const rfcStep0 = TotpService.generateTotpCode(rfcSecret, 0);
    const rfcStep1 = TotpService.generateTotpCode(rfcSecret, 30_000);
    const rfcStep2 = TotpService.generateTotpCode(rfcSecret, 60_000);
    expect(TotpService.matchTotpStep(rfcSecret, rfcStep0, 0)).toBe(0);
    expect(TotpService.matchTotpStep(rfcSecret, rfcStep1, 0)).toBe(1);
    expect(TotpService.matchTotpStep(rfcSecret, rfcStep2, 0)).toBeNull();
    expect(TotpService.verifyTotpCode(rfcSecret, rfcStep0, 0)).toBe(true);
    expect(TotpService.verifyTotpCode(rfcSecret, rfcStep2, 0)).toBe(false);
    expect(() => TotpService.generateTotpCode(rfcSecret, 0, -1)).toThrow(RangeError);

    harness.clock.now = new Date(10_000);
    const setup = await json<TotpSetupView>(await post(harness.app, "/v1/auth/totp/setup", {}, memberToken));
    const step0Code = TotpService.generateTotpCode(setup.secret, 10_000);
    expect((await post(harness.app, "/v1/auth/totp/verify", { code: step0Code }, memberToken)).status).toBe(200);
    expect(harness.container.database.get<{ last_used_step: number }>("SELECT last_used_step FROM user_totp WHERE user_id = ?", memberId)?.last_used_step).toBe(0);

    // Same-step replay at nowMs = 10_000 and -1 offset replay at nowMs = 40_000 both fail; step 1 login succeeds
    expect((await post(harness.app, "/v1/auth/login", { email: "member@example.com", password: "a-long-password", totpCode: step0Code })).status).toBe(401);
    harness.clock.now = new Date(40_000);
    expect((await post(harness.app, "/v1/auth/login", { email: "member@example.com", password: "a-long-password", totpCode: step0Code })).status).toBe(401);
    const step1Code = TotpService.generateTotpCode(setup.secret, 40_000);
    expect((await post(harness.app, "/v1/auth/login", { email: "member@example.com", password: "a-long-password", totpCode: step1Code })).status).toBe(200);
    expect((await post(harness.app, "/v1/auth/login", { email: "member@example.com", password: "a-long-password", totpCode: step1Code })).status).toBe(401);
  });

  it("rate limits authenticated TOTP endpoints at 10 requests per user and registers totp limiter", async () => {
    await post(harness.app, "/v1/auth/totp/setup", {}, memberToken);
    for (let i = 0; i < 10; i += 1) {
      const res = await post(harness.app, "/v1/auth/totp/verify", { code: "000000" }, memberToken);
      expect(res.status).toBe(400);
    }
    const throttledVerify = await post(harness.app, "/v1/auth/totp/verify", { code: "000000" }, memberToken);
    expect(throttledVerify.status).toBe(429);
    expect(throttledVerify.headers.get("retry-after")).toBeTruthy();

    // Shared user bucket also guards disable and regenerate
    expect((await post(harness.app, "/v1/auth/totp/disable", { currentPassword: "a-long-password", code: "000000" }, memberToken)).status).toBe(429);
    expect((await post(harness.app, "/v1/auth/totp/backup-codes/regenerate", { code: "000000" }, memberToken)).status).toBe(429);

    const limits = await json<{ entries: Array<{ limiter: string; maskedKey: string }> }>(
      await get(harness.app, "/v1/admin/rate-limits", adminToken),
    );
    expect(limits.entries.some((e) => e.limiter === "totp" && e.maskedKey === "us***")).toBe(true);
    const unlock = await harness.app.request("/v1/admin/rate-limits?limiter=totp", {
      method: "DELETE",
      headers: { authorization: `Bearer ${adminToken}` },
    });
    expect(unlock.status).toBe(200);
    expect((await post(harness.app, "/v1/auth/totp/verify", { code: "000000" }, memberToken)).status).toBe(400);
  });

  it("chains audit_log entries with SHA-256, handles legacy unchained rows, and detects tampering", async () => {
    expect((await get(harness.app, "/v1/admin/audit/verify")).status).toBe(401);
    expect((await get(harness.app, "/v1/admin/audit/verify", memberToken)).status).toBe(403);

    const verifyRes = await get(harness.app, "/v1/admin/audit/verify", adminToken);
    expect(verifyRes.status).toBe(200);
    expect(verifyRes.headers.get("cache-control")).toBe("no-store");
    const initial = await json<AuditChainVerification>(verifyRes);
    expect(initial.ok).toBe(true);
    expect(initial.verifiedCount).toBe(2);
    expect(initial.legacyUnchainedCount).toBe(0);
    expect(initial.firstBrokenId).toBeNull();
    expect(initial.headHash).toMatch(/^[a-f0-9]{64}$/);

    // Verify canonical hash matches first row GENESIS payload
    const rows = harness.container.database.all<{
      id: number; at: number; actor_user_id: string | null; action: string; target_user_id: string | null; details: string | null; prev_hash: string | null; entry_hash: string | null;
    }>("SELECT * FROM audit_log ORDER BY id ASC");
    const first = rows[0]!;
    const second = rows[1]!;
    expect(first.prev_hash).toBeNull();
    const expectedFirst = createHash("sha256")
      .update(`GENESIS|${first.at}|${first.actor_user_id ?? ""}|${first.action}|${first.target_user_id ?? ""}|${first.details ?? ""}`, "utf8")
      .digest("hex");
    expect(first.entry_hash).toBe(expectedFirst);
    expect(second.prev_hash).toBe(first.entry_hash);

    // Tamper with details on row 1 -> detects break at row 1
    harness.container.database.run("UPDATE audit_log SET details = ? WHERE id = ?", '{"role":"tampered"}', first.id);
    const brokenDetails = await json<AuditChainVerification>(await get(harness.app, "/v1/admin/audit/verify", adminToken));
    expect(brokenDetails).toEqual({
      ok: false,
      verifiedCount: 0,
      legacyUnchainedCount: 0,
      firstBrokenId: first.id,
      headHash: null,
    });

    // Simulate legacy unchained prefix followed by valid chained rows
    harness.container.database.run("DELETE FROM audit_log");
    harness.container.database.run(
      "INSERT INTO audit_log (at, actor_user_id, action, target_user_id, details, prev_hash, entry_hash) VALUES (1000, 'u1', 'legacy.event', 'u1', NULL, NULL, NULL)",
    );
    harness.container.audit.record({ actorUserId: memberId, action: "post_v8.one", targetUserId: memberId }, harness.clock.now);
    harness.container.audit.record({ actorUserId: memberId, action: "post_v8.two", targetUserId: memberId }, harness.clock.now);

    const withLegacy = await json<AuditChainVerification>(await get(harness.app, "/v1/admin/audit/verify", adminToken));
    expect(withLegacy.ok).toBe(true);
    expect(withLegacy.legacyUnchainedCount).toBe(1);
    expect(withLegacy.verifiedCount).toBe(2);
    expect(withLegacy.firstBrokenId).toBeNull();

    // Deleting middle chained row breaks the chain at the subsequent row
    const chainedIds = harness.container.database.all<{ id: number }>("SELECT id FROM audit_log WHERE entry_hash IS NOT NULL ORDER BY id ASC");
    harness.container.database.run("DELETE FROM audit_log WHERE id = ?", chainedIds[0]!.id);
    const deletedRowCheck = await json<AuditChainVerification>(await get(harness.app, "/v1/admin/audit/verify", adminToken));
    expect(deletedRowCheck).toEqual({
      ok: false,
      verifiedCount: 0,
      legacyUnchainedCount: 1,
      firstBrokenId: chainedIds[1]!.id,
      headHash: null,
    });

    // Inserting an unchained row after chaining started must fail verification
    harness.container.database.run("DELETE FROM audit_log");
    harness.container.audit.record({ actorUserId: memberId, action: "post_v8.valid", targetUserId: memberId }, harness.clock.now);
    harness.container.database.run(
      "INSERT INTO audit_log (at, actor_user_id, action, target_user_id, details, prev_hash, entry_hash) VALUES (2000, 'u1', 'injected.unchained', 'u1', NULL, NULL, NULL)",
    );
    const injected = harness.container.database.get<{ id: number }>("SELECT id FROM audit_log WHERE action = 'injected.unchained'")!;
    const injectedCheck = await json<AuditChainVerification>(await get(harness.app, "/v1/admin/audit/verify", adminToken));
    expect(injectedCheck).toMatchObject({ ok: false, verifiedCount: 1, firstBrokenId: injected.id });
  });
});
