import Foundation

// MARK: - Debrief Evidence Envelope

/// Typed data envelope carrying compressed session evidence for AI debrief generation.
/// Mirrors the pattern established by `QuickAssistContext` and `SessionContext`.
struct DebriefContext {
    let sessionId: String
    let condensedTranscript: String
    let transcriptWordCount: Int
    let transcriptEntryCount: Int
    let quickAssistManifest: String
    let coachFindingsManifest: String
    let responseCardSummary: String
    let metrics: DebriefMetrics
    let existingDebriefId: String?
}

// MARK: - Debrief Metrics

struct DebriefMetrics {
    let totalQuickAssistCalls: Int
    let successfulCalls: Int
    let failedCalls: Int
    let verifiedCalls: Int
    let averageLatencyMs: Int?
    let coachFindingCount: Int
    let responseCardCount: Int
    let unsupportedClaimTotal: Int
}
