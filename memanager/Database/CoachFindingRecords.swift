import Foundation

enum CoachIssueType: String, Codable, CaseIterable {
    case quickAssistFailureBurst = "quick_assist_failure_burst"
    case quickAssistHighLatency = "quick_assist_high_latency"
    case mermaidRecoveryLoop = "mermaid_recovery_loop"
    case progressiveParseInstability = "progressive_parse_instability"
    case transcriptStall = "transcript_stall"
    case crossSessionRegression = "cross_session_regression"
}

enum CoachFindingStatus: String, Codable, CaseIterable {
    case active
    case dismissed
    case applied
}

struct CoachEvidenceItem: Codable, Equatable {
    let label: String
    let value: String
}

struct CoachFindingRecord: Identifiable, Equatable {
    let id: String
    let sessionId: String?
    let threadId: String?
    let issueType: CoachIssueType
    let severity: WorkstreamEventSeverity
    let status: CoachFindingStatus
    let title: String
    let message: String
    let suggestedQuestion: String
    let suggestedContext: String
    let evidence: [CoachEvidenceItem]
    let dedupeKey: String
    let createdAt: Date
    let updatedAt: Date
    let dismissedAt: Date?

    init(
        id: String = UUID().uuidString,
        sessionId: String?,
        threadId: String?,
        issueType: CoachIssueType,
        severity: WorkstreamEventSeverity,
        status: CoachFindingStatus = .active,
        title: String,
        message: String,
        suggestedQuestion: String,
        suggestedContext: String,
        evidence: [CoachEvidenceItem],
        dedupeKey: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        dismissedAt: Date? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.threadId = threadId
        self.issueType = issueType
        self.severity = severity
        self.status = status
        self.title = title
        self.message = message
        self.suggestedQuestion = suggestedQuestion
        self.suggestedContext = suggestedContext
        self.evidence = evidence
        self.dedupeKey = dedupeKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.dismissedAt = dismissedAt
    }
}
