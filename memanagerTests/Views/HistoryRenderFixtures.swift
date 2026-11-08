import Foundation
@testable import memanager

/// Realistic data for the History, Practice, and Diagnostics render tests.
@MainActor
enum HistoryRenderFixtures {
    static let sessionID = "5A1C6E1E-6F0B-4D8B-9F4E-9C2B4F5E7A10"
    static let threadID = "thread-fixture-1"
    static let now = Date()

    static let sessions: [SessionRecord] = [
        SessionRecord(id: sessionID, startedAt: now.addingTimeInterval(-3_600), endedAt: now.addingTimeInterval(-1_200), state: "ended", transcriptWordCount: 2_140, screenshotCount: 2, hasResponse: true, provider: "Claude", model: "sonnet"),
        SessionRecord(id: "s2", startedAt: now.addingTimeInterval(-90_000), endedAt: now.addingTimeInterval(-87_000), state: "ended", transcriptWordCount: 860, screenshotCount: 0, hasResponse: true, provider: "OpenAI", model: "gpt"),
        SessionRecord(id: "s3", startedAt: now.addingTimeInterval(-700_000), endedAt: nil, state: "listening", transcriptWordCount: 0, screenshotCount: 0, hasResponse: false, provider: "Gemini", model: nil)
    ]

    static let metadata: [String: SessionCardMetadata] = [
        sessionID: SessionCardMetadata(id: sessionID, verifiedCount: 6, needsReviewCount: 2, failedCount: 1, pendingCount: 1, threadCount: 3, dominantTier: .deep, debriefPreview: "Strong on tradeoffs, drifted on complexity.", hasCoachFindings: true),
        "s2": SessionCardMetadata(id: "s2", verifiedCount: 3, needsReviewCount: 0, failedCount: 0, pendingCount: 0, threadCount: 1, dominantTier: .fast, debriefPreview: nil, hasCoachFindings: false)
    ]

    static let metrics = DebriefMetrics(totalQuickAssistCalls: 10, successfulCalls: 9, failedCalls: 1, verifiedCalls: 6, averageLatencyMs: 842, coachFindingCount: 2, responseCardCount: 4, unsupportedClaimTotal: 3)

    static let debrief: SessionDebrief = {
        let drills = [
            SessionDrill(id: "d1", sessionId: sessionID, debriefId: "db1", kind: .tradeoff, title: "Name the alternative", prompt: "State the trade off you were weighing and why the alternative lost.", transcriptSpan: "I guess we could cache it, or not", relatedThreadId: threadID, relatedTurnId: nil, createdAt: now),
            SessionDrill(id: "d2", sessionId: sessionID, debriefId: "db1", kind: .depth, title: "Own the complexity", prompt: "Walk through the time and space complexity and name the dominating term.", transcriptSpan: "it is probably linear or so", relatedThreadId: nil, relatedTurnId: nil, createdAt: now)
        ]
        return SessionDebrief(id: "db1", sessionId: sessionID, whatHappened: ["Forty minute coding round on string windows.", "Two follow ups on memory pressure."], strongMoments: ["Restated the problem before coding.", "Closed with a quantified result."], missedOpportunities: ["Hedged on complexity instead of stating it."], recommendedDrills: ["depth"], nextSessionFocus: ["State complexity in one sentence.", "Ask one clarifying question first."], createdAt: now, updatedAt: now, drills: drills)
    }()

    static let events: [WorkstreamTimelineEvent] = [
        event("e1", type: .transcript, severity: .info, offset: -1_800, title: "Question detected", summary: "Can you walk me through the sliding window approach?"),
        event("e2", type: .quickAssist, severity: .info, offset: -1_780, title: "Quick Assist answered", summary: "Say first: I would keep a last seen map and move the left edge past repeats.", threadId: threadID, turnId: "turn-1"),
        event("e3", type: .routingPolicy, severity: .info, offset: -1_779, title: "Routed to deep tier", summary: "Complexity moderate, confidence 0.82"),
        event("e4", type: .coachFinding, severity: .warning, offset: -1_500, title: "High latency burst", summary: "Three turns above four seconds in a row.", coachFindingId: "cf1"),
        event("e5", type: .screenshot, severity: .info, offset: -1_200, title: "Screenshot captured", summary: "1440x900 from the interview window"),
        event("e6", type: .experiment, severity: .critical, offset: -900, title: "Candidate failed verification", summary: "Two unsupported claims in the alternate provider answer.")
    ]

    static let card = PracticeCard(sessionID: sessionID, topicTag: "tradeoff", prompt: "State the core trade off you were weighing here, including why the alternative was rejected.", idealReasoning: "Anchor on the snippet and say the decision, the reason, and the trade off it implies in one sentence.", transcriptSnippet: "I guess we could cache it, or maybe not, depends", candidateAttemptSummary: "Trailed off on caching.", difficulty: .medium, sourceEvidence: .drill(drillID: "d1"))

    static let schedule = PracticeSchedule(cardID: card.id, repetitionCount: 1, easiness: 2.5, intervalDays: 2, nextReviewAt: now.addingTimeInterval(-60))

    static let providers: [ProviderSessionSummary] = [
        ProviderSessionSummary(provider: "Claude", model: "sonnet", callCount: 7, successCount: 7, errorCount: 0, averageLatencyMs: 780),
        ProviderSessionSummary(provider: "OpenAI", model: "gpt", callCount: 3, successCount: 2, errorCount: 1, averageLatencyMs: 1_420)
    ]

    static let providerStats: [ProviderStatsRecord] = [
        ProviderStatsRecord(date: "2026-09-01", provider: "Claude", model: "sonnet", callType: "quick_assist", callCount: 42, successCount: 40, errorCount: 2, totalDurationMs: 33_600, totalInputTokens: 90_000, totalOutputTokens: 21_000),
        ProviderStatsRecord(date: "2026-09-02", provider: "OpenAI", model: "gpt", callType: "quick_assist", callCount: 12, successCount: 11, errorCount: 1, totalDurationMs: 16_400, totalInputTokens: 30_000, totalOutputTokens: 8_000)
    ]

    static let skillReport = SkillProgressionReport(
        snapshots: (0..<6).map { index in
            SkillSnapshot(sessionId: "s\(index)", sessionDate: now.addingTimeInterval(Double(-index) * 86_400), verificationRate: [0.4, 0.5, 0.55, 0.62, 0.7, 0.74][index], unsupportedClaimDensity: [0.6, 0.5, 0.45, 0.3, 0.32, 0.2][index], coachFindingFrequency: [3, 2, 2, 1, 1, 1][index], averageLatencyMs: [1_400, 1_200, 1_250, 900, 850, 800][index], drillKinds: [.depth])
        },
        trends: [
            SkillTrend(metric: "verification_rate", direction: .improving, magnitude: 0.3, snapshotCount: 6),
            SkillTrend(metric: "unsupported_claim_density", direction: .improving, magnitude: 0.4, snapshotCount: 6),
            SkillTrend(metric: "coach_finding_frequency", direction: .stable, magnitude: 0, snapshotCount: 6),
            SkillTrend(metric: "average_latency", direction: .regressing, magnitude: 0.1, snapshotCount: 6)
        ],
        recurringWeakSpots: [.depth],
        promptBlock: ""
    )

    static let call = QuickAssistCallRecord(sessionId: sessionID, threadId: threadID, turnId: "turn-1", provider: "Claude", model: "sonnet", startedAt: now.addingTimeInterval(-1_780), completedAt: now.addingTimeInterval(-1_779), durationMs: 812, isFollowUp: false, transcriptLength: 640, hasScreenshot: true, hasPreviousResponse: false, responseLength: 420, status: "success", question: "Can you walk me through the sliding window approach?", responseText: "I would keep a last seen map and move the left edge past repeats.", contextMode: .conversation, modelTier: .deep, questionSource: .auto)

    static let replay = SessionReplay(session: sessions[0], events: events, snapshots: [], turns: [SessionReplayTurnEvidence(call: call, toolCalls: [])], transcriptEntries: [], coachFindings: [], debrief: debrief, practiceCards: [card])

    private static func event(_ id: String, type: WorkstreamEventType, severity: WorkstreamEventSeverity, offset: TimeInterval, title: String, summary: String, threadId: String? = nil, turnId: String? = nil, coachFindingId: String? = nil) -> WorkstreamTimelineEvent {
        WorkstreamTimelineEvent(id: id, type: type, severity: severity, timestamp: now.addingTimeInterval(offset), sessionId: sessionID, threadId: threadId, turnId: turnId, title: title, summary: summary, detail: nil, sourceRef: nil, coachFindingId: coachFindingId)
    }
}
