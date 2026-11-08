import Foundation

/// Wraps a line stream with staged timeout enforcement.
///
/// A pump task forwards lines while recording activity; a watchdog task
/// checks the applicable budget (first byte, inter chunk, total) and fails
/// the stream with a typed AIProviderError.timeout when one is exceeded.
enum StreamWatchdog {
    static func monitored(
        _ source: AsyncThrowingStream<String, Error>,
        policy: StreamTimeoutPolicy,
        checkInterval: TimeInterval = 1.0
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let activity = ActivityRecord()
            let start = Date()

            let pump = Task {
                do {
                    for try await line in source {
                        activity.record()
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            let watchdog = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
                    if Task.isCancelled { return }

                    let now = Date()
                    if now.timeIntervalSince(start) >= policy.total {
                        continuation.finish(throwing: AIProviderError.timeout(stage: .total))
                        return
                    }

                    let snapshot = activity.snapshot()
                    let idleSince = snapshot.lastActivity ?? start
                    let allowance = snapshot.hasActivity ? policy.interChunk : policy.firstByte
                    if now.timeIntervalSince(idleSince) >= allowance {
                        let stage: AIProviderError.TimeoutStage = snapshot.hasActivity ? .interChunk : .firstByte
                        continuation.finish(throwing: AIProviderError.timeout(stage: stage))
                        return
                    }
                }
            }

            continuation.onTermination = { _ in
                pump.cancel()
                watchdog.cancel()
            }
        }
    }
}

/// Lock guarded activity timestamp shared between the pump and the watchdog.
private final class ActivityRecord {
    struct Snapshot {
        let hasActivity: Bool
        let lastActivity: Date?
    }

    private let lock = NSLock()
    private var lastActivity: Date?

    func record() {
        lock.withLock {
            lastActivity = Date()
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(hasActivity: lastActivity != nil, lastActivity: lastActivity)
        }
    }
}
