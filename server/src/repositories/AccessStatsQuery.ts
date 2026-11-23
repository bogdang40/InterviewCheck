import type { Database } from "../db/Database.js";

/** Read only counts shared by the compliance summary and the metrics endpoint. */
export class AccessStatsQuery {
  constructor(private readonly db: Database) {}

  /**
   * "Now" for counting active rows: the requesting session's last_seen_at,
   * which authentication has just touched with the service clock, else the
   * wall clock.
   */
  referenceTimeMs(sessionId?: string): number {
    const row = sessionId ? this.db.get<{ last_seen_at: number }>("SELECT last_seen_at FROM sessions WHERE id = ?", sessionId) : undefined;
    return row ? Number(row.last_seen_at) : Date.now();
  }

  schemaVersion(): number {
    return this.db.userVersion();
  }

  usersTotal(): number {
    return this.count("SELECT COUNT(*) AS n FROM users");
  }

  activeAdminsTotal(): number {
    return this.count("SELECT COUNT(*) AS n FROM users WHERE role = 'admin' AND disabled = 0");
  }

  disabledUsersTotal(): number {
    return this.count("SELECT COUNT(*) AS n FROM users WHERE disabled = 1");
  }

  totpEnabledUsersTotal(): number {
    return this.hasTable("user_totp") ? this.count("SELECT COUNT(*) AS n FROM user_totp WHERE enabled = 1") : 0;
  }

  activeSessionsTotal(nowMs: number): number {
    return this.count("SELECT COUNT(*) AS n FROM sessions WHERE revoked_at IS NULL AND expires_at > ?", nowMs);
  }

  activeApiTokensTotal(nowMs: number): number {
    return this.hasTable("api_tokens")
      ? this.count("SELECT COUNT(*) AS n FROM api_tokens WHERE revoked_at IS NULL AND (expires_at IS NULL OR expires_at > ?)", nowMs)
      : 0;
  }

  auditLogTotal(): number {
    return this.count("SELECT COUNT(*) AS n FROM audit_log");
  }

  private count(sql: string, ...params: Array<string | number>): number {
    return Number(this.db.get<{ n: number }>(sql, ...params)?.n ?? 0);
  }

  private hasTable(name: string): boolean {
    return Boolean(this.db.get("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", name));
  }
}
