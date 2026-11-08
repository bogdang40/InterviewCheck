import Foundation

/// Serializes the synchronous storage boundary away from AppKit. Enqueueing on
/// MainActor preserves request order across sign out and an in-flight evaluation.
@MainActor
final class AccessPersistence {
    struct Session {
        let token: String?
        let cached: CachedAccessSnapshot?
    }

    private let queue = DispatchQueue(label: "com.interviewcheck.access.storage", qos: .utility)
    private let tokens: AccessTokenStoring
    private let cache: AccessSnapshotCaching

    init(tokens: AccessTokenStoring, cache: AccessSnapshotCaching) {
        self.tokens = tokens
        self.cache = cache
    }

    func readSession() async -> Result<Session, Error> {
        let tokens = tokens, cache = cache
        return await perform {
            Result {
                let token = try tokens.readForEvaluation()
                return Session(token: token, cached: token == nil ? nil : cache.load())
            }
        }
    }

    func saveToken(_ token: String) async -> Bool {
        let tokens = tokens
        return await perform { tokens.save(token) }
    }

    func saveSnapshot(_ snapshot: CachedAccessSnapshot) async {
        let cache = cache
        await perform { cache.save(snapshot) }
    }

    func clear() async {
        let tokens = tokens, cache = cache
        await perform { tokens.clear(); cache.clear() }
    }

    private func perform<Value>(_ operation: @escaping () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: operation()) }
        }
    }
}
