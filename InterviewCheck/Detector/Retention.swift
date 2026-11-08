import Foundation

/// Deletes interviews older than the retention setting.
enum InterviewRetention {
    static let choices: [(days: Int, title: String)] = [
        (0, "Forever"), (30, "30 days"), (90, "90 days"), (180, "6 months"), (365, "1 year"),
    ]

    /// Returns how many interviews were deleted.
    @discardableResult
    static func apply(days: Int, database: SessionDatabase, now: Date = Date()) -> Int {
        guard days > 0, let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return 0 }
        // Meeting recordings found by connectors age out with the interviews.
        database.deleteExternalRecordings(startedBefore: cutoff)
        return database.deleteInterviews(startedBefore: cutoff)
    }
}
