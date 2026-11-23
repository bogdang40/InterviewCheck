import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { Database } from "../src/db/Database.js";
import { LATEST_SCHEMA_VERSION, MigrationRunner } from "../src/db/Migrations.js";

const PYTHON_ACCOUNT_DB = join(dirname(fileURLToPath(import.meta.url)), "../../portable/api/account_db.py");

function pythonSchemaVersion(): number {
  const match = /^VERSION\s*=\s*(\d+)\s*$/m.exec(readFileSync(PYTHON_ACCOUNT_DB, "utf8"));
  if (!match) throw new Error(`No VERSION = <n> line in ${PYTHON_ACCOUNT_DB}`);
  return Number(match[1]);
}

/*
 * The Node server and the Python account service open the same access.sqlite.
 * Each refuses a user_version newer than its own, so the two must stay equal;
 * a bump on one side has to land on both. This fails fast here instead of in
 * portable/qa/test_access_service.py.
 */
describe("account database schema contract with the Python account service", () => {
  it("writes exactly the user_version that portable/api/account_db.py expects", () => {
    const db = new Database(":memory:");
    try {
      new MigrationRunner().run(db);
      expect(LATEST_SCHEMA_VERSION).toBe(pythonSchemaVersion());
      expect(db.userVersion()).toBe(pythonSchemaVersion());
    } finally {
      db.close();
    }
  });

  it("keeps the tables the Python service uses and adds no derived state to the versioned ladder", () => {
    const db = new Database(":memory:");
    try {
      new MigrationRunner().run(db);
      const tables = new Set(db.all<{ name: string }>("SELECT name FROM sqlite_master WHERE type = 'table'").map((row) => row.name));
      expect(tables.has("login_windows")).toBe(true);
      expect(tables.has("audit_chain_checkpoint")).toBe(false);
    } finally {
      db.close();
    }
  });
});
