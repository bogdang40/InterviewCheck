import Foundation

/// In memory index of every file under a resolved project root. Warmed once
/// via `rg --files` and kept fresh by `FSEventsWatcherActor`. Exact path lookups
/// use a dictionary; glob and directory queries scan the indexed records.
actor FSIndexActor {
    private var records: [String: FileRecord] = [:]
    private var warmed: Bool = false
    private let warmer: FSIndexWarmer
    private var warmTask: Task<Void, Error>?
    private var generation: UInt64 = 0

    init(warmer: FSIndexWarmer = FSIndexWarmer()) {
        self.warmer = warmer
    }

    func isWarm() -> Bool { warmed }

    func count() -> Int { records.count }

    func warm(root: URL) async throws {
        if warmed { return }
        if let warmTask {
            try await warmTask.value
            return
        }
        let attempt = generation
        let task = Task {
            let fresh = try await warmer.warm(root: root)
            try Task.checkCancellation()
            guard generation == attempt else { return }
            for record in fresh {
                records[record.relativePath] = record
            }
            warmed = true
        }
        warmTask = task
        defer {
            if generation == attempt { warmTask = nil }
        }
        try await task.value
    }

    func reset() {
        generation &+= 1
        warmTask?.cancel()
        warmTask = nil
        records.removeAll(keepingCapacity: true)
        warmed = false
    }

    func record(relativePath: String) -> FileRecord? {
        records[relativePath]
    }

    func invalidate(paths: [String], root: URL) {
        for path in paths {
            let absolute = root.appendingPathComponent(path)
            if let stamp = FileTimeRegistry.Stamp.of(url: absolute) {
                let existing = records[path]
                records[path] = FileRecord(
                    relativePath: path,
                    mtime: stamp.mtime,
                    size: stamp.size,
                    languageKind: existing?.languageKind ?? FileLanguageKind.from(path: path),
                    isHidden: existing?.isHidden ?? path.split(separator: "/").contains { $0.hasPrefix(".") },
                    isIgnored: existing?.isIgnored ?? false
                )
            } else {
                records.removeValue(forKey: path)
            }
        }
    }

    func files(
        subpath: String? = nil,
        globPattern: String? = nil,
        extensions: [String] = [],
        includeIgnored: Bool = false,
        includeHidden: Bool = false
    ) -> [FileRecord] {
        let matcher: FSIndexGlobMatcher? = globPattern.flatMap { FSIndexGlobMatcher(pattern: $0) }
        let extSet = Set(extensions.map { $0.lowercased() })
        return records.values.filter { record in
            if !includeIgnored, record.isIgnored { return false }
            if !includeHidden, record.isHidden { return false }
            if let prefix = subpath, !prefix.isEmpty, !record.relativePath.hasPrefix(prefix) { return false }
            if let matcher, !matcher.matches(record.relativePath) { return false }
            if !extSet.isEmpty {
                let ext = (record.relativePath as NSString).pathExtension.lowercased()
                if !extSet.contains(ext) { return false }
            }
            return true
        }
    }

    struct DirectoryListing: Equatable, Sendable {
        let files: [FileRecord]
        let subdirectories: [String]
    }

    func listing(
        of subpath: String,
        includeIgnored: Bool = false,
        includeHidden: Bool = false
    ) -> DirectoryListing {
        let normalized: String
        if subpath.isEmpty { normalized = "" }
        else { normalized = subpath.hasSuffix("/") ? subpath : subpath + "/" }
        var files: [FileRecord] = []
        var subdirectories = Set<String>()
        for record in records.values {
            if !includeIgnored, record.isIgnored { continue }
            if !includeHidden, record.isHidden { continue }
            if !normalized.isEmpty, !record.relativePath.hasPrefix(normalized) { continue }
            let tail = String(record.relativePath.dropFirst(normalized.count))
            if let slashIndex = tail.firstIndex(of: "/") {
                subdirectories.insert(String(tail[..<slashIndex]))
            } else if !tail.isEmpty {
                files.append(record)
            }
        }
        files.sort { $0.relativePath < $1.relativePath }
        return DirectoryListing(files: files, subdirectories: subdirectories.sorted())
    }
}
