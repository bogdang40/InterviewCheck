import Foundation
import SQLite3

/// RAII wrapper over one prepared SQLite statement: prepare and step failures
/// throw DatabaseError instead of being silently ignored, and finalize is
/// guaranteed by deinit. This is the adoption seam for converting DAO
/// extensions away from raw check-and-continue sqlite3_* calls.
final class SQLiteStatement {
    private let statement: OpaquePointer
    private let db: OpaquePointer
    private let sql: String

    init(db: OpaquePointer, sql: String) throws {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK,
              let statement = prepared else {
            sqlite3_finalize(prepared)
            throw DatabaseError.prepareFailed(
                sql: sql,
                message: String(cString: sqlite3_errmsg(db))
            )
        }
        self.statement = statement
        self.db = db
        self.sql = sql
    }

    deinit {
        sqlite3_finalize(statement)
    }

    // MARK: - Binding

    func bindText(_ value: String, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    func bindOptionalText(_ value: String?, at index: Int32) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func bindInt(_ value: Int, at index: Int32) {
        sqlite3_bind_int(statement, index, Int32(value))
    }

    func bindInt64(_ value: Int64, at index: Int32) {
        sqlite3_bind_int64(statement, index, value)
    }

    func bindOptionalInt64(_ value: Int64?, at index: Int32) {
        if let value {
            sqlite3_bind_int64(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func bindDouble(_ value: Double, at index: Int32) {
        sqlite3_bind_double(statement, index, value)
    }

    func bindNull(at index: Int32) {
        sqlite3_bind_null(statement, index)
    }

    /// Milliseconds since epoch, the layer's canonical timestamp encoding.
    func bindMillis(_ date: Date, at index: Int32) {
        sqlite3_bind_int64(statement, index, Int64(date.timeIntervalSince1970 * 1000))
    }

    func bindOptionalMillis(_ date: Date?, at index: Int32) {
        if let date {
            bindMillis(date, at: index)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func bindBool(_ value: Bool, at index: Int32) {
        sqlite3_bind_int(statement, index, value ? 1 : 0)
    }

    func bindOptionalBlob(_ value: Data?, at index: Int32) {
        guard let value, !value.isEmpty else {
            sqlite3_bind_null(statement, index)
            return
        }
        value.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
        }
    }

    // MARK: - Execution

    /// Steps a write statement to completion.
    func executeStep() throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.stepFailed(
                sql: sql,
                message: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    /// Advances a read statement. Returns true while a row is available.
    func stepRow() throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw DatabaseError.stepFailed(
                sql: sql,
                message: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    // MARK: - Column readers

    func columnText(_ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    func columnInt(_ index: Int32) -> Int {
        Int(sqlite3_column_int(statement, index))
    }

    func columnInt64(_ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func columnDouble(_ index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    func columnIsNull(_ index: Int32) -> Bool {
        sqlite3_column_type(statement, index) == SQLITE_NULL
    }

    func columnBool(_ index: Int32) -> Bool {
        sqlite3_column_int(statement, index) != 0
    }

    /// Inverse of bindMillis.
    func columnDate(_ index: Int32) -> Date {
        Date(timeIntervalSince1970: Double(columnInt64(index)) / 1000)
    }

    func columnOptionalDate(_ index: Int32) -> Date? {
        columnIsNull(index) ? nil : columnDate(index)
    }

    func columnBlob(_ index: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0 else { return nil }
        return Data(bytes: pointer, count: count)
    }
}
