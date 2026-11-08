import Foundation
import SQLite3

extension SessionDatabase {
    func columnExists(table: String, column: String) -> Bool {
        var exists = false

        performSync { db in
            guard let db else { return }

            let sql = "PRAGMA table_info(\(table));"
            var statement: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                return
            }

            defer { sqlite3_finalize(statement) }

            while sqlite3_step(statement) == SQLITE_ROW {
                guard let namePtr = sqlite3_column_text(statement, 1) else { continue }
                if String(cString: namePtr) == column {
                    exists = true
                    break
                }
            }
        }

        return exists
    }

    // MARK: - Schema Migrations

    func runMigrations() {
        runMigrations(steps: SessionDatabaseMigrationSteps.all)
    }

    /// Data driven migration ladder.
    ///
    /// The legacy if-ladder snapshotted user_version once, so when an early
    /// block failed and withheld its stamp, later blocks still ran and
    /// stamped the highest version over it: the failed block never retried.
    /// This runner re-reads user_version before each step and STOPS at the
    /// first failed step, so a failure can never be stamped over and always
    /// retries on the next launch. Backfills run only after a step's schema
    /// statements all succeeded, and count toward withholding the stamp.
    func runMigrations(steps: [MigrationStep]) {
        for step in steps.sorted(by: { $0.version < $1.version }) {
            guard getUserVersion() < step.version else { continue }

            var stepSucceeded = true
            for sql in step.statements {
                stepSucceeded = executeMigrationStatement(sql) && stepSucceeded
            }

            if stepSucceeded {
                for sql in step.backfills {
                    stepSucceeded = executeMigrationStatement(sql) && stepSucceeded
                }
            }

            if stepSucceeded {
                step.postStep?(self)
            }

            guard stepSucceeded else {
                NSLog("[SessionDatabase] Migration to v\(step.version) had failures; ladder stopped, will retry next launch")
                return
            }

            setUserVersion(step.version)
            NSLog("[SessionDatabase] Migrated to schema version \(step.version)")
        }
    }

    private func getUserVersion() -> Int {
        var version: Int = 0
        performSync { db in
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    version = Int(sqlite3_column_int(stmt, 0))
                }
            }
            sqlite3_finalize(stmt)
        }
        return version
    }

    private func setUserVersion(_ version: Int) {
        performSync { db in
            var errMsg: UnsafeMutablePointer<CChar>?
            sqlite3_exec(db, "PRAGMA user_version = \(version)", nil, nil, &errMsg)
            if errMsg != nil { sqlite3_free(errMsg) }
        }
    }

    /// Executes one migration statement. Errors that only mean the migration
    /// already ran (duplicate column, object already exists) are benign and
    /// preserve today's idempotent rerun behavior; anything else is logged
    /// and reported so the step's version stamp is withheld and the step
    /// retries on the next launch.
    private func executeMigrationStatement(_ sql: String) -> Bool {
        performSync { db in
            var errMsg: UnsafeMutablePointer<CChar>?
            sqlite3_exec(db, sql, nil, nil, &errMsg)
            guard let errMsg else { return true }
            let message = String(cString: errMsg)
            sqlite3_free(errMsg)
            if message.contains("duplicate column name") || message.contains("already exists") {
                return true
            }
            NSLog("[SessionDatabase] Migration statement failed: \(message) in: \(sql.prefix(90))")
            return false
        }
    }

}
