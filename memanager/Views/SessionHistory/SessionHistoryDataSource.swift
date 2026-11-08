import Foundation

/// Loads the session list and the 30 day provider stats off the main
/// thread and hands both back on the main queue.
struct SessionHistoryDataSource {
    var logger: SessionLogger = .shared
    var statsDays: Int = 30

    func load(limit: Int = 120, includeEmpty: Bool = false,
              completion: @escaping (Result<(ReviewSessionPage, [ProviderStatsRecord]), Error>) -> Void) {
        let logger = logger
        let statsDays = statsDays
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                let page = try logger.database.getReviewSessions(limit: limit, includeEmpty: includeEmpty)
                return (page, logger.getProviderStats(days: statsDays))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

/// Builds the workstream timeline filter from what the screen has selected.
enum SessionHistoryTimelineFilter {
    static let eventLimit = 180

    static func filter(
        base: WorkstreamTimelineFilter,
        sessionId: String?,
        threadId: String?,
        query: String,
        includeDebugEvents: Bool
    ) -> WorkstreamTimelineFilter {
        var filter = base
        filter.sessionId = sessionId
        filter.threadId = threadId
        filter.searchQuery = query
        filter.includeDebugEvents = includeDebugEvents
        filter.limit = eventLimit
        return filter
    }

    /// Threads shown for a session: those born in it plus global ones.
    static func availableThreads(
        _ summaries: [QuickAssistThreadSummary],
        sessionId: String?
    ) -> [QuickAssistThreadSummary] {
        summaries.filter { summary in
            guard let sessionId else { return true }
            return summary.originSessionId == nil || summary.originSessionId == sessionId
        }
    }

    /// Whether the selected thread still belongs to the selected session.
    static func threadSelectionSurvives(
        threadId: String?,
        in threads: [QuickAssistThreadSummary]
    ) -> Bool {
        guard let threadId else { return true }
        return threads.contains { $0.id == threadId }
    }
}
