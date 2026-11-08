import Foundation

/// Age and row caps for one telemetry table. User data (sessions, calls,
/// practice, debriefs, memory nodes) is never auto pruned; retention applies
/// only to append heavy diagnostic tables.
struct RetentionPolicy: Equatable {
    let table: String
    /// Millisecond epoch column the age cutoff applies to.
    let timestampColumn: String
    let maxAgeDays: Int
    let maxRows: Int

    static let defaults: [RetentionPolicy] = [
        RetentionPolicy(table: "debug_events", timestampColumn: "timestamp", maxAgeDays: 14, maxRows: 100_000),
        RetentionPolicy(table: "memory_retrieval_events", timestampColumn: "created_at", maxAgeDays: 30, maxRows: 50_000),
        RetentionPolicy(table: "quick_assist_policy_events", timestampColumn: "created_at", maxAgeDays: 90, maxRows: 100_000)
    ]

    func ageCutoffMillis(now: Date) -> Int64 {
        let cutoff = now.addingTimeInterval(-Double(maxAgeDays) * 24 * 60 * 60)
        return Int64(cutoff.timeIntervalSince1970 * 1000)
    }
}
