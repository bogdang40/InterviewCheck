import Foundation

/// What a sync wants the interviewer to know without failing, such as a list
/// cut short at a page limit. The caller sets a collector for the task;
/// connectors add to it. Outside a sync, notes go nowhere.
public final class SyncNotes: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    public init() {}

    @TaskLocal public static var current: SyncNotes?

    public var messages: [String] { lock.withLock { items } }

    public static func note(_ message: String) {
        guard let notes = current else { return }
        notes.lock.withLock { if !notes.items.contains(message) { notes.items.append(message) } }
    }

    /// A list stopped at its page limit with more left to read.
    static func cut(_ what: String, read count: Int) {
        let formatted = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
        note("Stopped after \(formatted) \(what); some may be missing.")
    }
}
