import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { SignedInResponse } from "../src/services/AuthService.js";
import { buildHarness, get, json, patch, post, type TestHarness } from "./support/TestContainer.js";

interface AuditEntryJson {
  id: number;
  at: string;
  actorUserId: string | null;
  action: string;
  targetUserId: string | null;
  details: Record<string, unknown> | null;
}

interface AuditPageJson {
  entries: AuditEntryJson[];
  nextBeforeId: number | null;
}

describe("admin audit filtering and pagination", () => {
  let harness: TestHarness;
  let adminToken: string;
  let adminId: string;
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
    adminId = admin.user.id;

    harness.clock.now = new Date("2026-09-02T13:00:00Z");
    const member = await json<SignedInResponse>(
      await post(harness.app, "/v1/auth/signup", { email: "member@example.com", password: "a-long-password" }),
    );
    memberId = member.user.id;

    harness.clock.now = new Date("2026-09-02T14:00:00Z");
    await patch(harness.app, `/v1/admin/users/${memberId}`, { disabled: true }, adminToken);

    harness.clock.now = new Date("2026-09-02T15:00:00Z");
    harness.container.audit.record(
      {
        actorUserId: adminId,
        action: "custom.percent_check",
        targetUserId: memberId,
        details: { note: "100% pass_rate" },
      },
      harness.clock.now,
    );
  });

  afterEach(() => {
    harness.container.close();
  });

  it("filters by q across action, actor, target, and details case-insensitively", async () => {
    const byDetails = await json<AuditPageJson>(await get(harness.app, "/v1/admin/audit?q=PASS_RATE", adminToken));
    expect(byDetails.entries.map((entry) => entry.action)).toEqual(["custom.percent_check"]);

    const byAction = await json<AuditPageJson>(await get(harness.app, "/v1/admin/audit?q=UPDATE_USER", adminToken));
    expect(byAction.entries.map((entry) => entry.action)).toEqual(["admin.update_user"]);

    const byTarget = await json<AuditPageJson>(
      await get(harness.app, `/v1/admin/audit?q=${encodeURIComponent(memberId.toUpperCase())}`, adminToken),
    );
    expect(byTarget.entries.map((entry) => entry.action)).toEqual([
      "custom.percent_check",
      "admin.update_user",
      "auth.signup",
    ]);
  });

  it("treats LIKE wildcards % and _ as literal characters in q, action, and actor", async () => {
    const onlyPct = await json<AuditPageJson>(await get(harness.app, "/v1/admin/audit?q=%25", adminToken));
    expect(onlyPct.entries.map((entry) => entry.action)).toEqual(["custom.percent_check"]);

    const actionPct = await json<AuditPageJson>(await get(harness.app, "/v1/admin/audit?action=%25", adminToken));
    expect(actionPct.entries).toHaveLength(0);

    const actionUnder = await json<AuditPageJson>(await get(harness.app, "/v1/admin/audit?action=auth_signup", adminToken));
    expect(actionUnder.entries).toHaveLength(0);

    const actionLiteralUnder = await json<AuditPageJson>(
      await get(harness.app, "/v1/admin/audit?action=update_user", adminToken),
    );
    expect(actionLiteralUnder.entries.map((entry) => entry.action)).toEqual(["admin.update_user"]);

    const actorPct = await json<AuditPageJson>(await get(harness.app, "/v1/admin/audit?actor=%25", adminToken));
    expect(actorPct.entries).toHaveLength(0);
  });

  it("filters by action and actor independently and in combination", async () => {
    const signups = await json<AuditPageJson>(await get(harness.app, "/v1/admin/audit?action=auth.signup", adminToken));
    expect(signups.entries).toHaveLength(2);

    const memberSignups = await json<AuditPageJson>(
      await get(harness.app, `/v1/admin/audit?action=auth.signup&actor=${encodeURIComponent(memberId.slice(0, 8))}`, adminToken),
    );
    expect(memberSignups.entries).toHaveLength(1);
    expect(memberSignups.entries[0]?.actorUserId).toBe(memberId);
  });

  it("filters by timezone-aware since and until boundaries", async () => {
    const since = encodeURIComponent("2026-09-02T15:00:00+02:00"); // 13:00:00Z
    const until = encodeURIComponent("2026-09-02T09:00:00-05:00"); // 14:00:00Z
    const page = await json<AuditPageJson>(await get(harness.app, `/v1/admin/audit?since=${since}&until=${until}`, adminToken));
    expect(page.entries.map((entry) => entry.action)).toEqual(["admin.update_user", "auth.signup"]);

    const inverted = await json<AuditPageJson>(
      await get(
        harness.app,
        `/v1/admin/audit?since=${encodeURIComponent("2026-09-02T16:00:00Z")}&until=${encodeURIComponent("2026-09-02T12:00:00Z")}`,
        adminToken,
      ),
    );
    expect(inverted.entries).toEqual([]);
    expect(inverted.nextBeforeId).toBeNull();
  });

  it("paginates deterministically with beforeId and nextBeforeId", async () => {
    const page1 = await json<AuditPageJson>(await get(harness.app, "/v1/admin/audit?limit=2", adminToken));
    expect(page1.entries).toHaveLength(2);
    expect(page1.nextBeforeId).toBe(page1.entries[1]?.id);

    const page2 = await json<AuditPageJson>(
      await get(harness.app, `/v1/admin/audit?limit=2&beforeId=${page1.nextBeforeId}`, adminToken),
    );
    expect(page2.entries).toHaveLength(2);
    expect(page2.nextBeforeId).toBeNull();

    const ids = [...page1.entries, ...page2.entries].map((entry) => entry.id);
    expect(new Set(ids).size).toBe(4);
    expect(ids).toEqual([...ids].sort((a, b) => b - a));
  });

  it("rejects naive timestamps, invalid dates, and bad beforeId values", async () => {
    for (const bad of ["2026-09-02T12:00:00", "2026-09-02", "2026-02-30T12:00:00Z", "not-a-date", ""]) {
      expect((await get(harness.app, `/v1/admin/audit?since=${encodeURIComponent(bad)}`, adminToken)).status).toBe(400);
      expect((await get(harness.app, `/v1/admin/audit?until=${encodeURIComponent(bad)}`, adminToken)).status).toBe(400);
    }
    for (const badId of ["0", "-1", "1.5", "abc", "", "1e2"]) {
      expect((await get(harness.app, `/v1/admin/audit?beforeId=${encodeURIComponent(badId)}`, adminToken)).status).toBe(400);
    }
    expect((await get(harness.app, `/v1/admin/audit?q=${"a".repeat(201)}`, adminToken)).status).toBe(400);
    expect((await get(harness.app, `/v1/admin/audit?action=${"a".repeat(121)}`, adminToken)).status).toBe(400);
    expect((await get(harness.app, `/v1/admin/audit?actor=${"a".repeat(129)}`, adminToken)).status).toBe(400);
  });
});
