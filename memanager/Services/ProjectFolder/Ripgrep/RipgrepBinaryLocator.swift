import Foundation

/// Finds the `rg` executable. Checks Homebrew's Apple silicon and Intel paths, the
/// system path, and finally the app bundle for a shipped copy. Result is cached
/// for the process lifetime since the binary location does not change.
final class RipgrepBinaryLocator {
    static let shared = RipgrepBinaryLocator()

    private let candidatePaths: [String]
    private var cached: URL?
    private var resolved = false
    private let lock = NSLock()

    init(candidatePaths: [String] = [
        "/opt/homebrew/bin/rg",
        "/usr/local/bin/rg",
        "/usr/bin/rg"
    ]) {
        self.candidatePaths = candidatePaths
    }

    /// Returns the path to `rg` if available, `nil` otherwise. Thread safe and
    /// memoized.
    func locate() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if resolved { return cached }
        resolved = true
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            cached = URL(fileURLWithPath: path)
            return cached
        }
        if let bundled = Bundle.main.url(forResource: "rg", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            cached = bundled
            return cached
        }
        cached = nil
        return nil
    }

    /// Clear the memo. Test only.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
        resolved = false
    }
}
