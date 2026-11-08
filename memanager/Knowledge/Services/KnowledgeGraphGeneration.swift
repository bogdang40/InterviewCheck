import Foundation

/// Serializes extraction commits with graph clearing. Each database owns its
/// own generation so unrelated stores and test fixtures remain independent.
final class KnowledgeGraphGeneration {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func snapshot() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func commit<T>(generation: UInt64, _ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard generation == value else { throw CancellationError() }
        return try body()
    }

    func clear(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try body()
        value &+= 1
    }
}
