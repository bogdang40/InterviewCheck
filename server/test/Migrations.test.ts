import { afterEach, describe, expect, it } from "vitest";
import { Database } from "../src/db/Database.js";
import { LATEST_SCHEMA_VERSION, MIGRATION_STEPS, MigrationRunner } from "../src/db/Migrations.js";

const V6_INDEXES = [
  "idx_users_created_id",
  "idx_audit_log_action_id",
  "idx_audit_log_actor_id",
  "idx_audit_log_at_id",
] as const;

const V7_TABLES = ["api_tokens", "login_email_windows"] as const;
const V8_TABLES = ["user_totp", "user_backup_codes"] as const;

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

  function tableNames(db: Database): Set<string> {
    const rows = db.all<{ name: string }>("SELECT name FROM sqlite_master WHERE type = 'table'");
    return new Set(rows.map((row) => row.name));
  }

  function auditColumns(db: Database): Set<string> {
    const rows = db.all<{ name: string }>("SELECT name FROM pragma_table_info('audit_log')");
    return new Set(rows.map((row) => row.name));
  }

  function totpColumns(db: Database): Set<string> {
    const rows = db.all<{ name: string }>("SELECT name FROM pragma_table_info('user_totp')");
    return new Set(rows.map((row) => row.name));
  }

  it("initializes a fresh database at user_version 8 with scale indexes, security tables, and TOTP/audit chain schema", () => {
    const db = openMemoryDb();
    new MigrationRunner().run(db);

    expect(db.userVersion()).toBe(LATEST_SCHEMA_VERSION);
    const indexes = indexNames(db);
    for (const name of V6_INDEXES) {
      expect(indexes.has(name)).toBe(true);
    }
    expect(indexes.has("idx_api_tokens_user")).toBe(true);
    expect(indexes.has("idx_backup_codes_user")).toBe(true);
    const tables = tableNames(db);
    for (const table of [...V7_TABLES, ...V8_TABLES]) {
      expect(tables.has(table)).toBe(true);
    }
    const cols = auditColumns(db);
    expect(cols.has("prev_hash")).toBe(true);
    expect(cols.has("entry_hash")).toBe(true);
    expect(totpColumns(db).has("last_used_step")).toBe(true);
  });

  it("upgrades an existing v5 database to v8 without losing rows", () => {
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

    expect(db.userVersion()).toBe(LATEST_SCHEMA_VERSION);
    const indexes = indexNames(db);
    for (const name of V6_INDEXES) {
      expect(indexes.has(name)).toBe(true);
    }
    expect(indexes.has("idx_api_tokens_user")).toBe(true);
    expect(indexes.has("idx_backup_codes_user")).toBe(true);
    for (const table of [...V7_TABLES, ...V8_TABLES]) {
      expect(tableNames(db).has(table)).toBe(true);
    }
    expect(totpColumns(db).has("last_used_step")).toBe(true);
    expect(db.get<{ n: number }>("SELECT COUNT(*) AS n FROM users")?.n).toBe(1);
    expect(db.get<{ n: number }>("SELECT COUNT(*) AS n FROM audit_log")?.n).toBe(1);
  });

  it("upgrades an existing v7 database to v8 idempotently while preserving legacy audit_log rows", () => {
    const db = openMemoryDb();
    new MigrationRunner(MIGRATION_STEPS.slice(0, 7)).run(db);
    expect(db.userVersion()).toBe(7);
    expect(tableNames(db).has("user_totp")).toBe(false);
    expect(auditColumns(db).has("entry_hash")).toBe(false);

    db.run(
      "INSERT INTO users (id, email, password_hash, role, disabled, created_at, updated_at) VALUES (?, ?, ?, ?, 0, ?, ?)",
      "user-7",
      "v7@example.invalid",
      "hash",
      "user",
      1000,
      1000,
    );
    db.run(
      "INSERT INTO audit_log (at, actor_user_id, action, target_user_id, details) VALUES (?, ?, ?, ?, ?)",
      1000,
      "user-7",
      "auth.signup",
      "user-7",
      null,
    );

    new MigrationRunner().run(db);
    new MigrationRunner().run(db);

    expect(db.userVersion()).toBe(LATEST_SCHEMA_VERSION);
    expect(tableNames(db).has("user_totp")).toBe(true);
    expect(tableNames(db).has("user_backup_codes")).toBe(true);
    expect(indexNames(db).has("idx_backup_codes_user")).toBe(true);
    expect(auditColumns(db).has("prev_hash")).toBe(true);
    expect(auditColumns(db).has("entry_hash")).toBe(true);
    expect(totpColumns(db).has("last_used_step")).toBe(true);
    const legacy = db.get<{ prev_hash: string | null; entry_hash: string | null }>("SELECT prev_hash, entry_hash FROM audit_log WHERE actor_user_id = 'user-7'");
    expect(legacy).toEqual({ prev_hash: null, entry_hash: null });
  });

  it("upgrades an interim database idempotently when v8 columns and user_totp already exist below user_version 8", () => {
    const dbA = openMemoryDb();
    new MigrationRunner().run(dbA);
    dbA.run(
      "INSERT INTO users (id, email, password_hash, role, disabled, created_at, updated_at) VALUES (?, ?, ?, ?, 0, ?, ?)",
      "user-a",
      "a@example.invalid",
      "hash",
      "user",
      1000,
      1000,
    );
    dbA.run(
      "INSERT INTO audit_log (at, actor_user_id, action, target_user_id, details) VALUES (?, ?, ?, ?, ?)",
      1000,
      "user-a",
      "auth.signup",
      "user-a",
      null,
    );
    dbA.setUserVersion(4);
    new MigrationRunner().run(dbA);
    expect(dbA.userVersion()).toBe(LATEST_SCHEMA_VERSION);
    expect(totpColumns(dbA).has("last_used_step")).toBe(true);
    expect(dbA.get<{ n: number }>("SELECT COUNT(*) AS n FROM users")?.n).toBe(1);
    expect(dbA.get<{ n: number }>("SELECT COUNT(*) AS n FROM audit_log")?.n).toBe(1);

    const dbB = openMemoryDb();
    new MigrationRunner(MIGRATION_STEPS.slice(0, 7)).run(dbB);
    dbB.exec(`CREATE TABLE user_totp (
      user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
      secret_enc TEXT NOT NULL,
      enabled INTEGER NOT NULL DEFAULT 0 CHECK(enabled IN (0,1)),
      verified_at INTEGER,
      created_at INTEGER NOT NULL
    )`);
    dbB.exec(`CREATE TABLE user_backup_codes (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      code_hash TEXT NOT NULL,
      used_at INTEGER,
      created_at INTEGER NOT NULL
    )`);
    dbB.exec("ALTER TABLE audit_log ADD COLUMN prev_hash TEXT");
    dbB.exec("ALTER TABLE audit_log ADD COLUMN entry_hash TEXT");
    expect(totpColumns(dbB).has("last_used_step")).toBe(false);
    expect(dbB.userVersion()).toBe(7);

    new MigrationRunner().run(dbB);
    expect(dbB.userVersion()).toBe(LATEST_SCHEMA_VERSION);
    expect(totpColumns(dbB).has("last_used_step")).toBe(true);
    expect(auditColumns(dbB).has("prev_hash")).toBe(true);
    expect(auditColumns(dbB).has("entry_hash")).toBe(true);
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
    db.setUserVersion(LATEST_SCHEMA_VERSION + 1);
    expect(() => new MigrationRunner().run(db)).toThrow("This account database version is unsupported.");
  });
});
