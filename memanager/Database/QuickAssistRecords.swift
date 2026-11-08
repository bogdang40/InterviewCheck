import Foundation

enum QuickAssistQuestionSource: String, Codable, Equatable {
    case none
    case manual
    case auto
}

enum QuickAssistVerificationStatus: String, Codable, Equatable {
    case pending
    case verified
    case needsReview
    case failed
}

enum QuickAssistTurnFeedbackStatus: String, Codable, Equatable {
    case none
    case accepted
    case rejected
}

enum QuickAssistCandidateRole: String, Codable, Equatable, CaseIterable {
    case currentRoute = "current_route"
    case sameProviderDeep = "same_provider_deep"
    case alternateProvider = "alternate_provider"

    var displayLabel: String {
        switch self {
        case .currentRoute:
            return "Current Route"
        case .sameProviderDeep:
            return "Deep Tier"
        case .alternateProvider:
            return "Alternate Provider"
        }
    }
}

struct QuickAssistOutcomeScore: Equatable {
    let verificationComponent: Double
    let unsupportedClaimPenalty: Double
    let feedbackComponent: Double
    let latencyComponent: Double
    let total: Double
    let rationale: String
}

struct QuickAssistVerificationRecord: Equatable {
    let status: QuickAssistVerificationStatus
    let confidence: Double?
    let unsupportedClaimCount: Int
    let missingQuestions: [String]
    let suggestedFollowUp: String?

    static let pending = QuickAssistVerificationRecord(
        status: .pending,
        confidence: nil,
        unsupportedClaimCount: 0,
        missingQuestions: [],
        suggestedFollowUp: nil
    )
}

struct QuickAssistThreadSummary: Identifiable, Equatable {
    let id: String
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let selectedMode: QuickAssistThreadMode
    let originSessionId: String?
    let parentThreadId: String?
    let branchedFromTurnId: String?
    let turnCount: Int
    let lastTurnAt: Date?
    let previewText: String?
    let hasRecordedCalls: Bool

    init(
        id: String,
        title: String,
        createdAt: Date,
        updatedAt: Date,
        selectedMode: QuickAssistThreadMode = .auto,
        originSessionId: String?,
        parentThreadId: String? = nil,
        branchedFromTurnId: String? = nil,
        turnCount: Int,
        lastTurnAt: Date?,
        previewText: String?,
        hasRecordedCalls: Bool = true
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.selectedMode = selectedMode
        self.originSessionId = originSessionId
        self.parentThreadId = parentThreadId
        self.branchedFromTurnId = branchedFromTurnId
        self.turnCount = turnCount
        self.lastTurnAt = lastTurnAt
        self.previewText = previewText
        self.hasRecordedCalls = hasRecordedCalls
    }
}

enum QuickAssistExperimentStatus: String, Codable, Equatable {
    case running
    case completed
    case adopted
}

struct QuickAssistCandidate: Identifiable, Equatable {
    let id: String
    let threadId: String
    let turnId: String
    let label: String
    let role: QuickAssistCandidateRole
    let provider: String
    let model: String
    let modelTier: QuickAssistModelTier
    let verificationStatus: QuickAssistVerificationStatus
    let unsupportedClaimCount: Int
    let feedbackStatus: QuickAssistTurnFeedbackStatus
    let latencyMs: Int?
    let score: QuickAssistOutcomeScore
    let isWinner: Bool
}

struct QuickAssistExperiment: Identifiable, Equatable {
    let id: String
    let sessionId: String
    let sourceThreadId: String
    let sourceTurnId: String
    let status: QuickAssistExperimentStatus
    let selectedIntent: QuickAssistIntent?
    let routeConfidence: Double?
    let winnerCandidateId: String?
    let createdAt: Date
    let updatedAt: Date
    let candidates: [QuickAssistCandidate]
}

struct QuickAssistPolicyEventRecord {
    let sessionId: String
    let threadId: String
    let turnId: String
    let policyVersion: String
    let selectedIntent: QuickAssistIntent
    let routeConfidence: Double
    let routeOverride: QuickAssistIntent?
    let decisionVector: String
    let createdAt: Date

    init(
        sessionId: String,
        threadId: String,
        turnId: String,
        policyVersion: String,
        selectedIntent: QuickAssistIntent,
        routeConfidence: Double,
        routeOverride: QuickAssistIntent?,
        decisionVector: String,
        createdAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.threadId = threadId
        self.turnId = turnId
        self.policyVersion = policyVersion
        self.selectedIntent = selectedIntent
        self.routeConfidence = routeConfidence
        self.routeOverride = routeOverride
        self.decisionVector = decisionVector
        self.createdAt = createdAt
    }
}

// MARK: - Transcript Entry Record
