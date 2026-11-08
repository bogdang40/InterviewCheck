import Foundation

/// Default credential I/O during XCTest stays in this process. Tests that
/// exercise Security status handling still inject their copyMatching closure.
final class TestCredentialStore {
    static let shared = TestCredentialStore()
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(for key: String) -> Data? {
        lock.withLock { values[key] }
    }

    func save(_ data: Data, for key: String) {
        lock.withLock { values[key] = data }
    }

    func remove(_ key: String) {
        lock.withLock { _ = values.removeValue(forKey: key) }
    }
}
