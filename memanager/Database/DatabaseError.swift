import Foundation

/// Typed failures for the SQLite layer. DAO extensions adopt these
/// incrementally through SQLiteStatement and the throwing bridge methods;
/// legacy non throwing paths keep working until each is converted.
enum DatabaseError: Error, LocalizedError, Equatable {
    case connectionUnavailable
    case prepareFailed(sql: String, message: String)
    case stepFailed(sql: String, message: String)
    case beginFailed(message: String)
    case commitFailed(message: String)
    case batchFailed(operation: String)

    var errorDescription: String? {
        switch self {
        case .connectionUnavailable:
            return "Database connection is unavailable."
        case .prepareFailed(let sql, let message):
            return "Failed to prepare statement (\(message)): \(sql)"
        case .stepFailed(let sql, let message):
            return "Failed to execute statement (\(message)): \(sql)"
        case .beginFailed(let message):
            return "Failed to begin transaction: \(message)"
        case .commitFailed(let message):
            return "Failed to commit transaction: \(message)"
        case .batchFailed(let operation):
            return "Statement batch reported failure: \(operation)"
        }
    }
}
