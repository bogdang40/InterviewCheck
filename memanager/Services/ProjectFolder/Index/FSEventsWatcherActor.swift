import Foundation
import CoreServices

/// Wraps `FSEventStreamCreate` so the live index can stay fresh. Coalesces
/// events over a 50 ms window and dispatches them to an `async` closure on a
/// background task. One instance per resolved project root.
actor FSEventsWatcherActor {
    private var stream: FSEventStreamRef?
    private var root: URL?
    private var onChange: (@Sendable ([String]) async -> Void)?

    func start(root: URL, onChange: @Sendable @escaping ([String]) async -> Void) async throws {
        if stream != nil { return }
        self.root = root
        self.onChange = onChange
        let context = UnsafeMutablePointer<FSEventStreamContext>.allocate(capacity: 1)
        context.initialize(to: FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        ))
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcherActor>.fromOpaque(info).takeUnretainedValue()
            let cf = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue()
            var collected: [String] = []
            for i in 0..<CFArrayGetCount(cf) {
                if let raw = CFArrayGetValueAtIndex(cf, i) {
                    let cfPath = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
                    collected.append(cfPath as String)
                }
            }
            Task { await watcher.handle(absolutePaths: collected) }
            _ = count
        }
        let pathsToWatch = [root.path] as CFArray
        let sinceNow = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        let latency: CFTimeInterval = 0.05
        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            context,
            pathsToWatch,
            sinceNow,
            latency,
            flags
        ) else {
            context.deinitialize(count: 1)
            context.deallocate()
            throw FSWatcherError.streamCreateFailed
        }
        self.stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(s)
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        onChange = nil
        root = nil
    }

    fileprivate func handle(absolutePaths: [String]) async {
        guard let root, let onChange else { return }
        let rootPath = root.resolvingSymlinksInPath().path
        let altRootPath = root.standardizedFileURL.path
        var relatives: [String] = []
        for absolute in absolutePaths {
            let resolved = URL(fileURLWithPath: absolute).resolvingSymlinksInPath().path
            let candidate = resolved.hasPrefix(rootPath + "/")
                ? String(resolved.dropFirst(rootPath.count + 1))
                : (resolved.hasPrefix(altRootPath + "/") ? String(resolved.dropFirst(altRootPath.count + 1)) : nil)
            if let c = candidate, !c.isEmpty { relatives.append(c) }
        }
        if !relatives.isEmpty { await onChange(relatives) }
    }

    enum FSWatcherError: Error, LocalizedError {
        case streamCreateFailed
        var errorDescription: String? { "FSEvents stream could not be created." }
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }
}
