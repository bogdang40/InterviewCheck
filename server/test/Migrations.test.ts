import { afterEach, describe, expect, it } from "vitest";
import { Database } from "../src/db/Database.js";
import { MIGRATION_STEPS, MigrationRunner } from "../src/db/Migrations.js";

const V6_INDEXES = [
  "idx_users_created_id",
  "idx_audit_log_action_id",
  "idx_audit_log_actor_id",
  "idx_audit_log_at_id",
] as const;

describe("account database migrations", () => {
  const openDbs: Database[] = [];

  function openMemoryDb(): Database {
    const db = new Database(":memory:");
    openDbs.push(db);
    return db;
  }

  afterEach(() => {
    while (openDbs.length > 0) {
      openDbs.pop()?.close();
    }
  });

  function indexNames(db: Database): Set<string> {
    const rows = db.all<{ name: string }>("SELECT name FROM sqlite_master WHERE type = 'index'");
    return new Set(rows.map((row) => row.name));
  }

  it("initializes a fresh database at user_version 6 with all scale indexes", () => {
    const db = openMemoryDb();
    new MigrationRunner().run(db);

    expect(db.userVersion()).toBe(6);
    const indexes = indexNames(db);
    for (const name of V6_INDEXES) {
      expect(indexes.has(name)).toBe(true);
    }
  });

  it("upgrades an existing v5 database to v6 without losing rows", () => {
    const db = openMemoryDb();
    new MigrationRunner(MIGRATION_STEPS.slice(0, 5)).run(db);
    expect(db.userVersion()).toBe(5);
    for (const name of V6_INDEXES) {
      expect(indexNames(db).has(name)).toBe(false);
    }

    db.run(
      "INSERT INTO users (id, email, password_hash, role, disabled, created_at, updated_at) VALUES (?, ?, ?, ?, 0, ?, ?)",
      "user-1",
      "user1@example.invalid",
      "hash",
      "user",
      1000,
      1000,
    );
    db.run(
      "INSERT INTO audit_log (at, actor_user_id, action, target_user_id, details) VALUES (?, ?, ?, ?, ?)",
      1000,
      "user-1",
      "auth.signup",
      "user-1",
      null,
    );

    new MigrationRunner().run(db);
    new MigrationRunner().run(db);

    expect(db.userVersion()).toBe(6);
    const indexes = indexNames(db);
    for (const name of V6_INDEXES) {
      expect(indexes.has(name)).toBe(true);
    }
    expect(db.get<{ n: number }>("SELECT COUNT(*) AS n FROM users")?.n).toBe(1);
    expect(db.get<{ n: number }>("SELECT COUNT(*) AS n FROM audit_log")?.n).toBe(1);
  });

  it("uses v6 indexes in SQLite query plans for users and audit_log lookups", () => {
    const db = openMemoryDb();
    new MigrationRunner().run(db);

    const auditActionPlan = db
      .all<{ detail: string }>("EXPLAIN QUERY PLAN SELECT * FROM audit_log WHERE action = ? ORDER BY id DESC LIMIT 50", "auth.login")
      .map((row) => row.detail)
      .join(" | ");
    expect(auditActionPlan).toContain("idx_audit_log_action_id");

    const auditAtPlan = db
      .all<{ detail: string }>("EXPLAIN QUERY PLAN SELECT * FROM audit_log ORDER BY at DESC, id DESC LIMIT 50")
      .map((row) => row.detail)
      .join(" | ");
    expect(auditAtPlan).toContain("idx_audit_log_at_id");

    const auditActorPlan = db
      .all<{ detail: string }>("EXPLAIN QUERY PLAN SELECT * FROM audit_log WHERE actor_user_id = ? ORDER BY id DESC LIMIT 50", "user-1")
      .map((row) => row.detail)
      .join(" | ");
    expect(auditActorPlan).toContain("idx_audit_log_actor_id");

    const usersPlan = db
      .all<{ detail: string }>("EXPLAIN QUERY PLAN SELECT * FROM users ORDER BY created_at DESC, id ASC LIMIT 50")
      .map((row) => row.detail)
      .join(" | ");
    expect(usersPlan).toContain("idx_users_created_id");
  });

  it("rejects databases newer than the supported schema version", () => {
    const db = openMemoryDb();
    db.setUserVersion(7);
    expect(() => new MigrationRunner().run(db)).toThrow("This account database version is unsupported.");
  });
});
