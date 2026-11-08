import Foundation

/// Fans out `url.resourceValues` stats for a list of relative paths against a
/// root, bounded by a concurrency limit. Used to rank glob and search results
/// by modification time without forcing callers to block on each stat in turn.
struct ConcurrentStat {
    static func modificationDates(
        relativePaths: [String],
        root: URL,
        concurrency: Int = 16
    ) async -> [String: Date] {
        if relativePaths.isEmpty { return [:] }
        return await withTaskGroup(of: (String, Date?).self, returning: [String: Date].self) { group in
            var started = 0
            let initial = min(concurrency, relativePaths.count)
            for _ in 0..<initial {
                let path = relativePaths[started]
                started += 1
                group.addTask { (path, Self.modifiedAt(relative: path, root: root)) }
            }
            var out: [String: Date] = [:]
            while let pair = await group.next() {
                if let date = pair.1 { out[pair.0] = date }
                if started < relativePaths.count {
                    let path = relativePaths[started]
                    started += 1
                    group.addTask { (path, Self.modifiedAt(relative: path, root: root)) }
                }
            }
            return out
        }
    }

    private static func modifiedAt(relative: String, root: URL) -> Date? {
        let url = root.appendingPathComponent(relative)
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }
}
