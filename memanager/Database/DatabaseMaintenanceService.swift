import Foundation
import SQLite3

/// Periodic retention enforcement for the telemetry tables plus WAL
/// checkpointing and a conservative, freelist gated VACUUM.
///
/// Deletes run in LIMIT batches, each batch its own queue hop, so retention
/// never holds the database write lock for long stretches.
final class DatabaseMaintenanceService {
    /// Resolved lazily so constructing the service (at AppDelegate init, on
    /// the main thread) never triggers the database's first-touch DDL and
    /// migrations; those happen on the background maintenance pass instead.
    private let databaseProvider: () -> SessionDatabase
    private var database: SessionDatabase { databaseProvider() }
    private let policies: [RetentionPolicy]
    private let defaults: UserDefaults
    private var timer: Timer?

    static let batchSize = 1000
    private static let runInterval: TimeInterval = 24 * 60 * 60
    private static let initialDelay: TimeInterval = 10
    private static let vacuumMinimumInterval: TimeInterval = 7 * 24 * 60 * 60
    private static let vacuumFreelistThreshold = 0.25
    private static let lastVacuumDefaultsKey = "memanager.maintenance.lastVacuumAt"

    init(
        databaseProvider: @escaping () -> SessionDatabase = { .shared },
        policies: [RetentionPolicy] = RetentionPolicy.defaults,
        defaults: UserDefaults = AppDefaults.standard
    ) {
        self.databaseProvider = databaseProvider
        self.policies = policies
        self.defaults = defaults
    }

    convenience init(
        database: SessionDatabase,
        policies: [RetentionPolicy] = RetentionPolicy.defaults,
        defaults: UserDefaults = AppDefaults.standard
    ) {
        self.init(databaseProvider: { database }, policies: policies, defaults: defaults)
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: Self.initialDelay, repeats: false) { [weak self] _ in
            self?.runInBackground()
            self?.scheduleRepeating()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func scheduleRepeating() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.runInterval, repeats: true) { [weak self] _ in
            self?.runInBackground()
        }
    }

    private func runInBackground() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.runOnce()
        }
    }

    /// Synchronous maintenance pass; the test entry point.
    func runOnce(now: Date = Date()) {
        for policy in policies {
            pruneByAge(policy, now: now)
            pruneByRowCap(policy)
        }
        checkpoint()
        vacuumIfWorthwhile(now: now)
    }

    private func pruneByAge(_ policy: RetentionPolicy, now: Date) {
        let cutoff = policy.ageCutoffMillis(now: now)
        let sql = """
        DELETE FROM \(policy.table)
        WHERE rowid IN (
            SELECT rowid FROM \(policy.table)
            WHERE \(policy.timestampColumn) < ?
            LIMIT \(Self.batchSize)
        )
        """
        runBatchedDelete(sql: sql, operation: "pruneByAge(\(policy.table))") { statement in
            statement.bindInt64(cutoff, at: 1)
        }
    }

    private func pruneByRowCap(_ policy: RetentionPolicy) {
        var totalDeleted = 0
        while true {
            let overflow: Int
            do {
                overflow = try database.performSyncThrowing { db in
                    let count = try SQLiteStatement(db: db, sql: "SELECT COUNT(*) FROM \(policy.table)")
                    _ = try count.stepRow()
                    return count.columnInt(0) - policy.maxRows
                }
            } catch {
                database.reportSwallowedError(error, operation: "pruneByRowCap(\(policy.table))")
                return
            }
            guard overflow > 0 else { break }

            let batch = min(overflow, Self.batchSize)
            do {
                try database.performSyncThrowing { db in
                    let sql = """
                    DELETE FROM \(policy.table)
                    WHERE rowid IN (
                        SELECT rowid FROM \(policy.table)
                        ORDER BY \(policy.timestampColumn) ASC
                        LIMIT \(batch)
                    )
                    """
                    let statement = try SQLiteStatement(db: db, sql: sql)
                    try statement.executeStep()
                }
            } catch {
                database.reportSwallowedError(error, operation: "pruneByRowCap(\(policy.table))")
                return
            }
            totalDeleted += batch
        }
        if totalDeleted > 0 {
            NSLog("[DatabaseMaintenance] pruneByRowCap(\(policy.table)) removed \(totalDeleted) rows")
        }
    }

    private func runBatchedDelete(
        sql: String,
        operation: String,
        bind: (SQLiteStatement) -> Void
    ) {
        var totalDeleted = 0
        while true {
            let deletedThisBatch: Int
            do {
                deletedThisBatch = try database.performSyncThrowing { db in
                    let statement = try SQLiteStatement(db: db, sql: sql)
                    bind(statement)
                    try statement.executeStep()
                    return Int(sqlite3_changes(db))
                }
            } catch {
                database.reportSwallowedError(error, operation: operation)
                return
            }
            totalDeleted += deletedThisBatch
            if deletedThisBatch < Self.batchSize {
                break
            }
        }
        if totalDeleted > 0 {
            NSLog("[DatabaseMaintenance] \(operation) removed \(totalDeleted) rows")
        }
    }

    private func checkpoint() {
        do {
            try database.performSyncThrowing { db in
                _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
            }
        } catch {
            database.reportSwallowedError(error, operation: "walCheckpoint")
        }
    }

    private func vacuumIfWorthwhile(now: Date) {
        let lastVacuum = defaults.double(forKey: Self.lastVacuumDefaultsKey)
        guard now.timeIntervalSince1970 - lastVacuum >= Self.vacuumMinimumInterval else { return }

        let freelistRatio: Double
        do {
            freelistRatio = try database.performSyncThrowing { db in
                let freelist = try Self.pragmaValue("freelist_count", db: db)
                let pages = try Self.pragmaValue("page_count", db: db)
                guard pages > 0 else { return 0 }
                return Double(freelist) / Double(pages)
            }
        } catch {
            database.reportSwallowedError(error, operation: "vacuumProbe")
            return
        }

        guard freelistRatio > Self.vacuumFreelistThreshold else { return }

        do {
            try database.performSyncThrowing { db in
                let vacuum = try SQLiteStatement(db: db, sql: "VACUUM")
                try vacuum.executeStep()
            }
            defaults.set(now.timeIntervalSince1970, forKey: Self.lastVacuumDefaultsKey)
            NSLog("[DatabaseMaintenance] VACUUM completed (freelist ratio \(String(format: "%.2f", freelistRatio)))")
        } catch {
            database.reportSwallowedError(error, operation: "vacuum")
        }
    }

    private static func pragmaValue(_ pragma: String, db: OpaquePointer) throws -> Int {
        let statement = try SQLiteStatement(db: db, sql: "PRAGMA \(pragma)")
        guard try statement.stepRow() else { return 0 }
        return statement.columnInt(0)
    }
}
