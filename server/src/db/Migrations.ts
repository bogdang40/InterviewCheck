import type { Database } from "./Database.js";

export interface MigrationStep {
  readonly version: number;
  readonly statements: readonly string[] | ((database: Database) => readonly string[]);
}

/**
 * Append only ladder, mirrored on PRAGMA user_version exactly like the macOS
 * app's SessionDatabase. Never edit a shipped step; add a new one.
 */
export const MIGRATION_STEPS: readonly MigrationStep[] = [
  {
    version: 1,
    statements: [
      `CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY,
        email TEXT NOT NULL UNIQUE,
        password_hash TEXT NOT NULL,
        role TEXT NOT NULL DEFAULT 'user',
        disabled INTEGER NOT NULL DEFAULT 0,
        trial_ends_at INTEGER,
        complimentary_until INTEGER,
        stripe_customer_id TEXT UNIQUE,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        last_login_at INTEGER
      )`,
      `CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        token_hash TEXT NOT NULL UNIQUE,
        device_name TEXT,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        last_seen_at INTEGER NOT NULL,
        revoked_at INTEGER
      )`,
      `CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id, expires_at)`,
      `CREATE TABLE IF NOT EXISTS subscriptions (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        status TEXT NOT NULL,
        price_id TEXT,
        plan TEXT,
        current_period_end INTEGER,
        cancel_at_period_end INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )`,
      `CREATE INDEX IF NOT EXISTS idx_subscriptions_user ON subscriptions(user_id, updated_at DESC)`,
      `CREATE TABLE IF NOT EXISTS stripe_events (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        received_at INTEGER NOT NULL
      )`,
      `CREATE TABLE IF NOT EXISTS audit_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        at INTEGER NOT NULL,
        actor_user_id TEXT,
        action TEXT NOT NULL,
        target_user_id TEXT,
        details TEXT
      )`,
      `CREATE INDEX IF NOT EXISTS idx_audit_log_at ON audit_log(at DESC)`,
    ],
  },
  {
    version: 2,
    statements: [
      // When the row last changed status; past_due grace is measured from here.
      `ALTER TABLE subscriptions ADD COLUMN status_changed_at INTEGER`,
    ],
  },
  {
    version: 3,
    statements: [
      // Set once the event's effects are in the database. A claim that never
      // reached this point (process killed mid apply) is re-claimable after
      // a staleness window so Stripe's redelivery is not answered as a dup.
      `ALTER TABLE stripe_events ADD COLUMN applied_at INTEGER`,
    ],
  },
  {
    version: 4,
    statements: [
      `CREATE TABLE IF NOT EXISTS subscription_versions (id TEXT PRIMARY KEY,version INTEGER NOT NULL)`,
      `CREATE TABLE IF NOT EXISTS checkout_requests (
        user_id TEXT PRIMARY KEY REFERENCES users(id),plan TEXT NOT NULL,request_id TEXT NOT NULL,
        expires_at INTEGER NOT NULL,return_base TEXT NOT NULL,url TEXT)`,
      `CREATE TABLE IF NOT EXISTS login_windows (address TEXT PRIMARY KEY,start INTEGER NOT NULL,hits INTEGER NOT NULL)`,
    ],
  },
  {
    version: 5,
    statements: (database) => database.get("SELECT 1 FROM pragma_table_info('subscriptions') WHERE name = ?", "stripe_customer_id")
      ? [] : ["ALTER TABLE subscriptions ADD COLUMN stripe_customer_id TEXT"],
  },
];

export class MigrationRunner {
  constructor(private readonly steps: readonly MigrationStep[] = MIGRATION_STEPS) {}

  run(database: Database): void {
    const sorted = [...this.steps].sort((a, b) => a.version - b.version);
    if (database.userVersion() > (sorted.at(-1)?.version ?? 0)) {
      throw new Error("This account database version is unsupported.");
    }
    for (const step of sorted) {
      if (database.userVersion() >= step.version) continue;
      database.transaction(() => {
        if (database.userVersion() >= step.version) return;
        const statements = typeof step.statements === "function" ? step.statements(database) : step.statements;
        for (const statement of statements) {
          database.exec(statement);
        }
        database.setUserVersion(step.version);
      });
    }
  }
}
