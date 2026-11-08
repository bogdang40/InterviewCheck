import Foundation

/// What each mailbox message held, kept between syncs so a sync downloads
/// only messages it has not seen. Keyed by mailbox and UIDVALIDITY (a
/// rebuilt mailbox starts over). In memory only; nothing is written to disk.
public final class MailInviteCache: @unchecked Sendable {
    public static let shared = MailInviteCache()
    private let lock = NSLock()
    /// mailbox key → message UID → its invite events (empty: no invite).
    private var mailboxes: [String: [Int: [CalendarEvent]]] = [:]

    public init() {}

    func events(_ key: String) -> [Int: [CalendarEvent]] {
        lock.withLock { mailboxes[key] ?? [:] }
    }

    /// Stores what was learned, keeping only messages still in the search.
    func update(_ key: String, with learned: [Int: [CalendarEvent]], keeping uids: Set<Int>) {
        lock.withLock {
            var known = mailboxes[key] ?? [:]
            known.merge(learned) { $1 }
            mailboxes[key] = known.filter { uids.contains($0.key) }
        }
    }
}
