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
  {
    version: 6,
    statements: [
      `CREATE INDEX IF NOT EXISTS idx_users_created_id ON users(created_at DESC, id ASC)`,
      `CREATE INDEX IF NOT EXISTS idx_audit_log_action_id ON audit_log(action, id DESC)`,
      `CREATE INDEX IF NOT EXISTS idx_audit_log_actor_id ON audit_log(actor_user_id, id DESC)`,
      `CREATE INDEX IF NOT EXISTS idx_audit_log_at_id ON audit_log(at DESC, id DESC)`,
    ],
  },
  {
    version: 7,
    statements: [
      `CREATE TABLE IF NOT EXISTS api_tokens (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        token_prefix TEXT NOT NULL,
        token_hash TEXT NOT NULL UNIQUE,
        scopes_json TEXT NOT NULL DEFAULT '[]',
        created_at INTEGER NOT NULL,
        expires_at INTEGER,
        last_used_at INTEGER,
        revoked_at INTEGER
      )`,
      `CREATE INDEX IF NOT EXISTS idx_api_tokens_user ON api_tokens(user_id, created_at DESC)`,
      `CREATE TABLE IF NOT EXISTS login_email_windows (
        email TEXT PRIMARY KEY,
        start INTEGER NOT NULL,
        hits INTEGER NOT NULL
      )`,
    ],
  },
  {
    version: 8,
    statements: (database) => {
      const statements: string[] = [
        `CREATE TABLE IF NOT EXISTS user_totp (
          user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
          secret_enc TEXT NOT NULL,
          enabled INTEGER NOT NULL DEFAULT 0 CHECK(enabled IN (0,1)),
          verified_at INTEGER,
          created_at INTEGER NOT NULL,
          last_used_step INTEGER
        )`,
        `CREATE TABLE IF NOT EXISTS user_backup_codes (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          code_hash TEXT NOT NULL,
          used_at INTEGER,
          created_at INTEGER NOT NULL
        )`,
        `CREATE INDEX IF NOT EXISTS idx_backup_codes_user ON user_backup_codes(user_id, used_at)`,
      ];
      const hasUserTotp = Boolean(database.get("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", "user_totp"));
      if (hasUserTotp && !database.get("SELECT 1 FROM pragma_table_info('user_totp') WHERE name = ?", "last_used_step")) {
        statements.push("ALTER TABLE user_totp ADD COLUMN last_used_step INTEGER");
      }
      for (const col of ["prev_hash", "entry_hash"]) {
        if (!database.get("SELECT 1 FROM pragma_table_info('audit_log') WHERE name = ?", col)) {
          statements.push(`ALTER TABLE audit_log ADD COLUMN ${col} TEXT`);
        }
      }
      return statements;
    },
  },
  {
    version: 9,
    statements: [
      // Never written: per address limits live in memory, per account limits in login_email_windows.
      `DROP TABLE IF EXISTS login_windows`,
    ],
  },
];

export const LATEST_SCHEMA_VERSION = Math.max(...MIGRATION_STEPS.map((step) => step.version));

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
