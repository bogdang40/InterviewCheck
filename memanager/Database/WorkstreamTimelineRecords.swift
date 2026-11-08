import Foundation

enum WorkstreamEventType: String, Codable, CaseIterable {
    case quickAssist = "quick_assist"
    case routingPolicy = "routing_policy"
    case transcript = "transcript"
    case screenshot = "screenshot"
    case memory = "memory"
    case memoryRetrieval = "memory_retrieval"
    case responseCard = "response_card"
    case experiment = "experiment"
    case debrief = "debrief"
    case debug = "debug"
    case coachFinding = "coach_finding"
}

enum WorkstreamEventSeverity: String, Codable, CaseIterable {
    case info
    case warning
    case critical
}

struct WorkstreamTimelineEvent: Identifiable, Equatable {
    let id: String
    let type: WorkstreamEventType
    let severity: WorkstreamEventSeverity
    let timestamp: Date
    let sessionId: String?
    let threadId: String?
    let turnId: String?
    let title: String
    let summary: String
    let detail: String?
    let sourceRef: String?
    let coachFindingId: String?
}

struct WorkstreamTimelineFilter: Equatable {
    var sessionId: String?
    var threadId: String?
    var searchQuery: String
    var includeDebugEvents: Bool
    var enabledEventTypes: Set<WorkstreamEventType>?
    var limit: Int

    init(
        sessionId: String? = nil,
        threadId: String? = nil,
        searchQuery: String = "",
        includeDebugEvents: Bool = true,
        enabledEventTypes: Set<WorkstreamEventType>? = nil,
        limit: Int = 160
    ) {
        self.sessionId = sessionId
        self.threadId = threadId
        self.searchQuery = searchQuery
        self.includeDebugEvents = includeDebugEvents
        self.enabledEventTypes = enabledEventTypes
        self.limit = limit
    }
}

struct WorkstreamThreadMetrics: Equatable {
    let threadId: String
    let title: String
    let turnCount: Int
    let successCount: Int
    let errorCount: Int
    let averageDurationMs: Int?
    let latestResponseSnippet: String?
    let contextModeMix: [QuickAssistContextMode: Int]
}

struct WorkstreamThreadComparison: Equatable {
    let left: WorkstreamThreadMetrics
    let right: WorkstreamThreadMetrics
    let highlights: [String]
}

// MARK: - Proactive Failure Coach
