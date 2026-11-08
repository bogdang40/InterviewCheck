import Foundation
import Combine

// MARK: - Date Grouping

enum SessionDateBucket: String, CaseIterable {
    case today = "Today"
    case yesterday = "Yesterday"
    case thisWeek = "This Week"
    case earlier = "Earlier"
}

struct SessionDateGroup: Identifiable {
    let bucket: SessionDateBucket
    let sessions: [SessionRecord]
    var id: String { bucket.rawValue }
    var count: Int { sessions.count }

    static func group(sessions: [SessionRecord], calendar: Calendar = .current) -> [SessionDateGroup] {
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday

        var buckets: [SessionDateBucket: [SessionRecord]] = [:]
        for session in sessions {
            let date = session.startedAt
            let bucket: SessionDateBucket
            if date >= startOfToday {
                bucket = .today
            } else if date >= startOfYesterday {
                bucket = .yesterday
            } else if date >= startOfWeek {
                bucket = .thisWeek
            } else {
                bucket = .earlier
            }
            buckets[bucket, default: []].append(session)
        }

        return SessionDateBucket.allCases.compactMap { bucket in
            guard let sessions = buckets[bucket], !sessions.isEmpty else { return nil }
            return SessionDateGroup(bucket: bucket, sessions: sessions)
        }
    }
}

// MARK: - Sorting and Filtering

enum SessionSortOrder: String, CaseIterable, Identifiable {
    case newest = "Newest"
    case oldest = "Oldest"
    case byDuration = "Duration"
    case byThreadCount = "Threads"

    var id: String { rawValue }
}

enum SessionFilter: String, CaseIterable, Identifiable, Hashable {
    case hasDebrief = "Has Debrief"
    case hasCoachFindings = "Coach Findings"
    case highActivity = "High Activity"

    var id: String { rawValue }
}

// MARK: - Session Card Metadata

/// Pre-computed enrichment data for each session card.
struct SessionCardMetadata: Identifiable {
    let id: String
    let verifiedCount: Int
    let needsReviewCount: Int
    let failedCount: Int
    let pendingCount: Int
    let threadCount: Int
    let dominantTier: QuickAssistModelTier
    let debriefPreview: String?
    let hasCoachFindings: Bool

    var totalTurns: Int { verifiedCount + needsReviewCount + failedCount + pendingCount }

    var verifiedFraction: Double {
        totalTurns > 0 ? Double(verifiedCount) / Double(totalTurns) : 0
    }

    var needsReviewFraction: Double {
        totalTurns > 0 ? Double(needsReviewCount) / Double(totalTurns) : 0
    }

    var failedFraction: Double {
        totalTurns > 0 ? Double(failedCount) / Double(totalTurns) : 0
    }
}

/// A result can only publish into the selection and request that started it.
struct SessionHistoryRequestGate {
    private(set) var sessionID: String?
    private var requestID = UUID()

    mutating func select(_ id: String?) {
        sessionID = id
        requestID = UUID()
    }

    mutating func begin(sessionID: String) -> UUID {
        select(sessionID)
        return requestID
    }

    func accepts(_ request: UUID, sessionID: String) -> Bool {
        request == requestID && sessionID == self.sessionID
    }
}
