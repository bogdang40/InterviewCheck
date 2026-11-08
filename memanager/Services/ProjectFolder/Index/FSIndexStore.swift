import Foundation

/// Process wide registry of `FSIndexActor` instances, keyed by canonical root
/// path. Each project root warms at most once, and the matching
/// `FSEventsWatcherActor` keeps it fresh for the lifetime of the process.
actor FSIndexStore {
    static let shared = FSIndexStore()

    private var indexes: [String: FSIndexActor] = [:]
    private var watchers: [String: FSEventsWatcherActor] = [:]

    func index(for root: URL) -> FSIndexActor {
        let key = Self.key(for: root)
        if let existing = indexes[key] { return existing }
        let actor = FSIndexActor()
        indexes[key] = actor
        return actor
    }

    func ensureWatcher(for root: URL, index: FSIndexActor) async {
        let key = Self.key(for: root)
        if watchers[key] != nil { return }
        let watcher = FSEventsWatcherActor()
        watchers[key] = watcher
        do {
            try await watcher.start(root: root) { paths in
                await index.invalidate(paths: paths, root: root)
            }
        } catch {
            watchers.removeValue(forKey: key)
        }
    }

    func reset() async {
        for watcher in watchers.values { await watcher.stop() }
        watchers.removeAll()
        for index in indexes.values { await index.reset() }
        indexes.removeAll()
    }

    private static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}
