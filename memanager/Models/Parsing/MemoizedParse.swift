import Foundation

/// Content keyed memoization for pure parse functions.
///
/// Returning the SAME cached instance for unchanged input is the point:
/// parse products carry init time UUID identities, so instance stability is
/// what keeps SwiftUI diffing effective across body passes. Small LRU
/// capacity because inputs churn rarely (a handful of live responses).
final class MemoizedParse<Output> {
    private struct Entry {
        let input: String
        let output: Output
    }

    private let lock = NSLock()
    private let capacity: Int
    /// Most recently used last. Linear scan is fine at this capacity.
    private var entries: [Entry] = []

    init(capacity: Int = 4) {
        self.capacity = max(1, capacity)
    }

    func value(for input: String, compute: (String) -> Output) -> Output {
        lock.lock()
        if let index = entries.lastIndex(where: { $0.input == input }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            lock.unlock()
            return entry.output
        }
        lock.unlock()

        // Compute outside the lock: parsers can be expensive and reentrant
        // callers must not deadlock. A rare duplicate compute is acceptable.
        let output = compute(input)

        lock.lock()
        if let index = entries.lastIndex(where: { $0.input == input }) {
            // Another thread finished first; keep ITS instance for stability.
            let entry = entries.remove(at: index)
            entries.append(entry)
            lock.unlock()
            return entry.output
        }
        entries.append(Entry(input: input, output: output))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        lock.unlock()
        return output
    }
}
