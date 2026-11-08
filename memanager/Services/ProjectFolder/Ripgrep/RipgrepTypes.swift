import Foundation

/// A single regex match produced by `rg --json`. Paths are always returned relative
/// to the scope the service was invoked against, so the sandbox root never leaks
/// into model output.
struct RipgrepMatch: Equatable, Sendable {
    let relativePath: String
    let lineNumber: Int
    let byteOffset: Int
    let lineText: String
    let submatches: [Range<Int>]
    let contextBefore: [RipgrepContextLine]
    var contextAfter: [RipgrepContextLine]
}

/// A single context line associated with a `RipgrepMatch`. `text` has its trailing
/// newline stripped so callers can format freely.
struct RipgrepContextLine: Equatable, Sendable {
    let lineNumber: Int
    let text: String
}

/// A single file hit produced by `rg --files`. `modifiedAt` is populated by the
/// caller after a concurrent stat pass; ripgrep itself does not report it.
struct RipgrepFileHit: Equatable, Sendable {
    let relativePath: String
    var modifiedAt: Date?
}

/// Failure modes the service exposes. `binaryNotFound` is the only case a caller
/// is expected to recover from (by falling back to a slower backend).
enum RipgrepError: Error, LocalizedError, Sendable {
    case binaryNotFound
    case spawnFailed(String)
    case nonZeroExit(Int32, String)
    case invalidJSON(String)
    case outputLimitExceeded(stream: String, limit: Int)
    case outputReadFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "ripgrep binary not found. Install with: brew install ripgrep"
        case .spawnFailed(let message):
            return "Failed to launch ripgrep: \(message)"
        case .nonZeroExit(let code, let stderr):
            return "ripgrep exited with code \(code): \(stderr)"
        case .outputLimitExceeded(let stream, let limit):
            return "ripgrep \(stream) exceeded the \(limit) byte output limit. Narrow the search scope or pattern and retry."
        case .outputReadFailed(let message):
            return "Could not read ripgrep output: \(message)"
        case .invalidJSON(let message):
            return "Could not decode ripgrep output: \(message)"
        }
    }
}
