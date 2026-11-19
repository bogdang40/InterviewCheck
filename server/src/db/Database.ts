import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { closeSync, mkdirSync, openSync } from "node:fs";
import { dirname } from "node:path";

export type SqlParam = SQLInputValue;

/**
 * Thin synchronous SQLite facade over node:sqlite. Repositories depend on
 * this class rather than on the driver so the driver can be swapped (or
 * faked) without touching query code.
 */
export class Database {
  private readonly connection: DatabaseSync;
  private closed = false;

  constructor(path: string) {
    if (path !== ":memory:") {
      mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
      closeSync(openSync(path, "a", 0o600));
    }
    this.connection = new DatabaseSync(path);
    this.connection.exec("PRAGMA journal_mode = WAL");
    this.connection.exec("PRAGMA foreign_keys = ON");
    this.connection.exec("PRAGMA busy_timeout = 5000");
  }

  exec(sql: string): void {
    this.connection.exec(sql);
  }

  run(sql: string, ...params: SqlParam[]): { changes: number | bigint } {
    const result = this.connection.prepare(sql).run(...params);
    return { changes: result.changes };
  }

  get<Row>(sql: string, ...params: SqlParam[]): Row | undefined {
    return this.connection.prepare(sql).get(...params) as Row | undefined;
  }

  all<Row>(sql: string, ...params: SqlParam[]): Row[] {
    return this.connection.prepare(sql).all(...params) as Row[];
  }

  /** BEGIN IMMEDIATE so writers queue instead of failing on contention. */
  transaction<T>(work: () => T): T {
    this.connection.exec("BEGIN IMMEDIATE");
    try {
      const result = work();
      this.connection.exec("COMMIT");
      return result;
    } catch (error) {
      this.connection.exec("ROLLBACK");
      throw error;
    }
  }

  userVersion(): number {
    const row = this.get<{ user_version: number }>("PRAGMA user_version");
    return row?.user_version ?? 0;
  }

  setUserVersion(version: number): void {
    this.connection.exec(`PRAGMA user_version = ${Math.trunc(version)}`);
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.connection.close();
  }
}

/** Convert a JS boolean to the 0/1 integer SQLite expects as a bound value. */
export const sqlBool = (value: boolean): number => (value ? 1 : 0);

/** Convert an optional Date to a millisecond epoch column value. */
export const sqlDate = (value: Date | null | undefined): number | null =>
  value ? value.getTime() : null;

/** Convert a millisecond epoch column back to a Date. */
export const dateFromSql = (value: number | bigint | null | undefined): Date | null =>
  value === null || value === undefined ? null : new Date(Number(value));
