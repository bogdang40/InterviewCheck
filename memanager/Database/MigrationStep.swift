import Foundation

/// One version increment in the schema migration ladder.
///
/// The runner stamps `version` into `PRAGMA user_version` only when every
/// statement and backfill succeeded (statements whose errors merely mean
/// "already migrated" count as success). Backfills run only after all schema
/// statements succeeded, so data rewrites can never run against half applied
/// DDL.
struct MigrationStep {
    let version: Int
    /// Schema statements (CREATE/ALTER/INDEX). Order preserved.
    let statements: [String]
    /// Data backfills; run after DDL success and count toward the stamp.
    let backfills: [String]
    /// Swift side follow up work (the v4 FTS vtable probe); runs after a
    /// fully successful step, before stamping.
    let postStep: ((SessionDatabase) -> Void)?

    init(
        version: Int,
        statements: [String],
        backfills: [String] = [],
        postStep: ((SessionDatabase) -> Void)? = nil
    ) {
        self.version = version
        self.statements = statements
        self.backfills = backfills
        self.postStep = postStep
    }
}
