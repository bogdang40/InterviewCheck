import Foundation

/// Session scoped registry that remembers the mtime and size observed at each
/// read. Any future write tool can call `assert` before overwriting to catch
/// external edits. Ships ready even though no write tool exists yet.
actor FileTimeRegistry {
    struct Stamp: Equatable, Sendable {
        let mtime: Date
        let size: Int
    }

    enum AssertOutcome: Equatable, Sendable {
        case unchanged
        case driftedSince(Stamp)
        case neverRead
    }

    private var stamps: [String: Stamp] = [:]

    func record(path: String, stamp: Stamp) {
        stamps[path] = stamp
    }

    func assertState(path: String, current: Stamp) -> AssertOutcome {
        guard let prior = stamps[path] else { return .neverRead }
        if prior == current { return .unchanged }
        return .driftedSince(prior)
    }

    func snapshot(path: String) -> Stamp? {
        stamps[path]
    }

    func clear() {
        stamps.removeAll(keepingCapacity: true)
    }

    func count() -> Int {
        stamps.count
    }
}

extension FileTimeRegistry.Stamp {
    static func of(url: URL) -> FileTimeRegistry.Stamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        let size = (attrs[.size] as? Int) ?? 0
        return FileTimeRegistry.Stamp(mtime: mtime, size: size)
    }
}
