import Foundation

/// On disk spill directory for tool outputs that exceed the per call budget.
/// Lives under `~/.memanager/cache/tool-outputs/`. Self creates on first write
/// and trims to at most `maxFiles` by modification time.
final class ToolOutputCacheDir {
    static let shared = ToolOutputCacheDir()

    let baseURL: URL
    private let fileManager = FileManager.default
    private let maxFiles: Int
    private let lock = NSLock()

    init(baseURL: URL? = nil, maxFiles: Int = 200) {
        if let url = baseURL {
            self.baseURL = url
        } else if TestRuntime.isRunningUnitTests {
            self.baseURL = TestRuntime.temporaryDirectory.appendingPathComponent("tool-outputs", isDirectory: true)
        } else {
            self.baseURL = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(AppBrand.homeFolder, isDirectory: true)
                .appendingPathComponent("cache", isDirectory: true)
                .appendingPathComponent("tool-outputs", isDirectory: true)
        }
        self.maxFiles = maxFiles
    }

    func ensureReady() throws {
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true, attributes: nil)
    }

    func write(_ content: String) throws -> URL {
        try ensureReady()
        let url = baseURL.appendingPathComponent("\(UUID().uuidString).txt")
        try content.write(to: url, atomically: true, encoding: .utf8)
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.pruneIfNeeded()
        }
        return url
    }

    private func pruneIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard let items = try? fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        if items.count <= maxFiles { return }
        let sorted = items.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate < rhsDate
        }
        let excess = items.count - maxFiles
        for url in sorted.prefix(excess) {
            try? fileManager.removeItem(at: url)
        }
    }
}
