import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { SignedInResponse } from "../src/services/AuthService.js";
import { AuditChainVerifier, type AuditVerificationResult } from "../src/services/AuditChainVerifier.js";
import { buildHarness, get, json, post, type TestHarness } from "./support/TestContainer.js";

interface SummaryChainFields {
  auditChainOk: boolean | null;
  auditChainVerifiedAt: string | null;
}

describe("incremental audit chain verification", () => {
  let harness: TestHarness;
  let adminToken: string;

  beforeEach(async () => {
    harness = buildHarness();
    adminToken = (await json<SignedInResponse>(
      await post(harness.app, "/v1/auth/signup", { email: "owner@example.com", password: "a-long-password", adminSecret: "bootstrap-secret" }),
    )).token;
  });

  afterEach(() => {
    vi.restoreAllMocks();
    harness.container.close();
  });

  function record(count: number): void {
    for (let i = 0; i < count; i += 1) harness.container.audit.record({ actorUserId: null, action: `test.event_${i}` }, harness.clock.now);
  }

  async function verify(query = ""): Promise<AuditVerificationResult> {
    const res = await get(harness.app, `/v1/admin/audit/verify${query}`, adminToken);
    expect(res.status).toBe(200);
    return json<AuditVerificationResult>(res);
  }

  function lastAuditId(): number {
    return Number(harness.container.database.get<{ id: number }>("SELECT MAX(id) AS id FROM audit_log")!.id);
  }

  it("resumes from the stored checkpoint and still detects tampering after it", async () => {
    record(3);
    const first = await verify();
    expect(first).toMatchObject({ ok: true, mode: "incremental", verifiedCount: 4, firstBrokenId: null, verifiedThroughId: lastAuditId() });

    const scan = vi.spyOn(harness.container.audit, "chainRowsAfter");
    record(2);
    const second = await verify();
    expect(second).toMatchObject({ ok: true, verifiedCount: 6, verifiedThroughId: lastAuditId() });
    expect(scan.mock.calls[0]?.[0]).toBe(first.verifiedThroughId);

    record(2);
    const tamperedId = lastAuditId() - 1;
    harness.container.database.run("UPDATE audit_log SET details = ? WHERE id = ?", '{"tampered":true}', tamperedId);
    const broken = await verify();
    expect(broken).toMatchObject({ ok: false, firstBrokenId: tamperedId, verifiedThroughId: second.verifiedThroughId });
  });

  it("detects tampering before the checkpoint only with an explicit full verification", async () => {
    record(3);
    expect((await verify()).ok).toBe(true);
    harness.container.database.run("UPDATE audit_log SET details = ? WHERE id = 1", '{"tampered":true}');

    expect((await verify()).ok).toBe(true);
    const full = await verify("?full=true");
    expect(full).toMatchObject({ ok: false, mode: "full", firstBrokenId: 1, verifiedCount: 0 });
    expect((await get(harness.app, "/v1/admin/audit/verify?full=maybe", adminToken)).status).toBe(400);
  });

  it("walks the table in bounded batches and yields between them", async () => {
    record(6);
    const yields = vi.fn(async () => {});
    const verifier = new AuditChainVerifier(harness.container.audit, harness.container.auditCheckpoints, () => harness.clock.now, {
      batchSize: 2,
      yieldToEventLoop: yields,
    });
    const scan = vi.spyOn(harness.container.audit, "chainRowsAfter");
    const result = await verifier.verify("full");
    expect(result).toMatchObject({ ok: true, verifiedCount: 7 });
    expect(scan.mock.calls.every(([, limit]) => limit === 2)).toBe(true);
    expect(yields.mock.calls.length).toBeGreaterThanOrEqual(3);
  });

  it("reports the last verification on the compliance summary without walking the chain", async () => {
    const before = await json<SummaryChainFields>(await get(harness.app, "/v1/admin/compliance/summary", adminToken));
    expect(before).toMatchObject({ auditChainOk: null, auditChainVerifiedAt: null });

    await verify();
    const scan = vi.spyOn(harness.container.audit, "chainRowsAfter");
    const after = await json<SummaryChainFields>(await get(harness.app, "/v1/admin/compliance/summary", adminToken));
    expect(after).toMatchObject({ auditChainOk: true, auditChainVerifiedAt: harness.clock.now.toISOString() });
    expect(scan).not.toHaveBeenCalled();
  });
});
