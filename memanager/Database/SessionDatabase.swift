import Foundation
import SQLite3

/// SQLite-based database for storing session history, API calls, and analytics
final class SessionDatabase {
    static let shared = SessionDatabase()
    let knowledgeGraphGeneration = KnowledgeGraphGeneration()
    // Queue confined: active request ownership is consumed or invalidated in
    // the same database queue operation as its terminal write or deletion.
    var quickAssistCallOwners: [UUID: QuickAssistCallOwnership] = [:]
    var apiCallOwners: [UUID: String] = [:]
    
    private var db: OpaquePointer?
    private let dbQueue = DispatchQueue(label: "com.memanager.SessionDatabase", qos: .utility)
    private let queueIdentity = DispatchSpecificKey<Void>()

    /// Queue confined: read and written only inside performSync/performAsync
    /// bodies. The precondition turns any future off-queue access into a
    /// loud failure instead of a silent data race.
    var memoryFTSSupported: Bool {
        get {
            dispatchPrecondition(condition: .onQueue(dbQueue))
            return _memoryFTSSupported
        }
        set {
            dispatchPrecondition(condition: .onQueue(dbQueue))
            _memoryFTSSupported = newValue
        }
    }
    private var _memoryFTSSupported = false

    /// Queue confined like memoryFTSSupported: whether kg_nodes_fts exists.
    var knowledgeFTSSupported: Bool {
        get {
            dispatchPrecondition(condition: .onQueue(dbQueue))
            return _knowledgeFTSSupported
        }
        set {
            dispatchPrecondition(condition: .onQueue(dbQueue))
            _knowledgeFTSSupported = newValue
        }
    }
    private var _knowledgeFTSSupported = false

    private let databasePath: String

    /// Designated initializer with an injectable database location so tests can
    /// run against a temporary file instead of the production store. Production
    /// code must keep using `shared`.
    init(databasePath: String) {
        self.databasePath = databasePath
        dbQueue.setSpecific(key: queueIdentity, value: ())
        openDatabase()
        createTables()
        runMigrations()
        ensureDeferredIndices()
    }

    private convenience init() {
        // Singleton consumers in native and controller tests must never open
        // the user's history, including destructive history-maintenance tests.
        let path = TestRuntime.isRunningUnitTests
            ? TestRuntime.temporaryDirectory.appendingPathComponent("sessions.sqlite").path
            : SessionDatabase.defaultDatabasePath()
        self.init(databasePath: path)
    }
    
    deinit {
        // The final queued writer may release the last reference on dbQueue.
        // Dispatching synchronously onto that same queue would trap.
        if DispatchQueue.getSpecific(key: queueIdentity) != nil {
            closeDatabase()
        } else {
            dbQueue.sync { closeDatabase() }
        }
    }

    private func closeDatabase() {
        if let db { sqlite3_close(db) }
        db = nil
    }
    
    // MARK: - Database Setup
    
    private func openDatabase() {
        let dbPath = databasePath
        let directoryPath = (dbPath as NSString).deletingLastPathComponent
        
        // Create directory if needed
        if !FileManager.default.fileExists(atPath: directoryPath) {
            try? FileManager.default.createDirectory(atPath: directoryPath, withIntermediateDirectories: true)
        }
        
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            NSLog("[SessionDatabase] Error opening database: \(String(cString: sqlite3_errmsg(db)))")
        } else {
            NSLog("[SessionDatabase] Database opened at: \(dbPath)")
            // Purely additive for a single writer on one serial queue: WAL
            // keeps readers from blocking the writer and busy_timeout retries
            // instead of failing if another process ever holds the file.
            if sqlite3_exec(db, "PRAGMA busy_timeout = 5000", nil, nil, nil) != SQLITE_OK {
                NSLog("[SessionDatabase] busy_timeout pragma failed: \(String(cString: sqlite3_errmsg(db)))")
            }
            activateWALMode()
        }
    }

    /// `PRAGMA journal_mode = WAL` reports the resulting mode as a row; a
    /// discarded result can silently leave the database in rollback mode.
    private func activateWALMode() {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA journal_mode = WAL", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let modeCString = sqlite3_column_text(statement, 0) else {
            NSLog("[SessionDatabase] Failed to set WAL journal mode: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        let mode = String(cString: modeCString)
        if mode.lowercased() != "wal" {
            NSLog("[SessionDatabase] WAL not active, journal_mode=\(mode)")
        }
    }
    
    /// Forces the lazy singleton (DDL plus migrations on first touch) to
    /// initialize. Called from launch on a utility queue so the expensive
    /// first touch happens off the main thread whenever possible.
    func warmUp() {}

    private static func defaultDatabasePath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbDir = appSupport.appendingPathComponent("memanager/db")
        return dbDir.appendingPathComponent("sessions.sqlite").path
    }
}

// MARK: - Internal access bridge for feature specific extensions

extension SessionDatabase {
    /// Synchronously runs `body` on the database serial queue with a raw connection pointer.
    /// Intended only for extensions in this module that need direct SQLite access.
    func performSync<T>(_ body: (OpaquePointer?) -> T) -> T {
        var result: T!
        dbQueue.sync {
            result = body(db)
        }
        return result
    }

    /// Asynchronously runs `body` on the database serial queue.
    func performAsync(_ body: @escaping (OpaquePointer?) -> Void) {
        // Pending writes own their connection until they finish. A weak
        // capture drops queued history when the last external owner releases.
        dbQueue.async {
            body(self.db)
        }
    }

    /// Throwing variant of performSync: hands a guaranteed live connection to
    /// `body`, or throws when the connection is unavailable.
    func performSyncThrowing<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try dbQueue.sync {
            guard let db else {
                throw DatabaseError.connectionUnavailable
            }
            return try body(db)
        }
    }

    /// Wraps `body` in BEGIN IMMEDIATE / COMMIT. A BEGIN failure throws
    /// WITHOUT running the body (the legacy helper ran it untransacted); a
    /// body throw rolls back and rethrows the original error. Caller must
    /// already be on the database queue.
    func withTransactionThrowing(_ db: OpaquePointer, _ body: () throws -> Void) throws {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.beginFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        do {
            try body()
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw DatabaseError.commitFailed(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Single funnel for failures on public non throwing DAO paths. Plain
    /// NSLog on purpose: routing through SessionLogger would re-enter the
    /// database layer.
    func reportSwallowedError(_ error: Error, operation: String) {
        NSLog("[SessionDatabase] \(operation) failed: \(error.localizedDescription)")
    }

    /// Drains all queued performAsync writes and passively checkpoints the
    /// WAL, bounded so app termination can never hang on a stuck write.
    /// Because the queue is serial, the drain block runs only after every
    /// previously enqueued write has finished.
    func flush(timeout: TimeInterval = 2.0) {
        let checkpoint = DispatchWorkItem { [weak self] in
            if let self, let db = self.db {
                sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
            }
        }
        dbQueue.async(execute: checkpoint)
        // Waiting on the submitted work item lets libdispatch donate the
        // caller's priority to this serial queue and its preceding writes.
        if checkpoint.wait(timeout: .now() + timeout) == .timedOut {
            NSLog("[SessionDatabase] flush timed out after \(timeout)s; queued writes may be lost")
        }
    }
}

// MARK: - Let SQLite use transient bindings
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Shared binding and JSON helpers

extension SessionDatabase {
    func bindOptionalText(_ value: String?, at index: Int32, in stmt: OpaquePointer?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    func encodeStringArray(_ values: [String]) -> String? {
        let cleaned = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty,
              let data = try? JSONEncoder().encode(cleaned) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func decodeStringArray(_ raw: String?) -> [String] {
        guard let raw,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }
}
