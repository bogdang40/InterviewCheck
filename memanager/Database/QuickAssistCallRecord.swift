import Foundation

struct QuickAssistCallRecord {
    var id: Int64?
    let sessionId: String
    let threadId: String
    let turnId: String
    let provider: String
    let model: String
    let startedAt: Date
    var completedAt: Date?
    var durationMs: Int?
    let isFollowUp: Bool
    let transcriptLength: Int
    let hasScreenshot: Bool
    let hasPreviousResponse: Bool
    var responseLength: Int?
    var status: String  // "pending", "success", "error", "cancelled"
    var errorMessage: String?
    // Full context storage
    var transcriptText: String?
    var question: String?
    var extraContext: String?
    var requestPayload: String?
    var responseText: String?
    var rawResponseText: String?
    var guardedResponseText: String?
    var previousResponse: String?
    let contextMode: QuickAssistContextMode
    let modelTier: QuickAssistModelTier
    let questionSource: QuickAssistQuestionSource
    let routeConfidence: Double?
    var verificationStatus: QuickAssistVerificationStatus
    var verificationConfidence: Double?
    var unsupportedClaimCount: Int?
    var verificationMissingQuestions: [String]
    var verificationSuggestedFollowUp: String?
    let policyVersion: String?
    let routeOverride: String?
    let evidencePackManifest: String?
    var userFeedbackStatus: QuickAssistTurnFeedbackStatus
    var userFeedbackNote: String?
    var userFeedbackAt: Date?
    let experimentGroupId: String?
    let candidateLabel: String?
    let baseTurnId: String?
    let candidateRole: QuickAssistCandidateRole?

    var routeOverrideIntent: QuickAssistIntent? {
        routeOverride.flatMap(QuickAssistIntent.init(rawValue:))
    }
    
    init(
        id: Int64? = nil,
        sessionId: String,
        threadId: String? = nil,
        turnId: String? = nil,
        provider: String,
        model: String,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        durationMs: Int? = nil,
        isFollowUp: Bool = false,
        transcriptLength: Int = 0,
        hasScreenshot: Bool = false,
        hasPreviousResponse: Bool = false,
        responseLength: Int? = nil,
        status: String = "pending",
        errorMessage: String? = nil,
        transcriptText: String? = nil,
        question: String? = nil,
        extraContext: String? = nil,
        requestPayload: String? = nil,
        responseText: String? = nil,
        rawResponseText: String? = nil,
        guardedResponseText: String? = nil,
        previousResponse: String? = nil,
        contextMode: QuickAssistContextMode = .conversation,
        modelTier: QuickAssistModelTier = .fast,
        questionSource: QuickAssistQuestionSource = .none,
        routeConfidence: Double? = nil,
        verificationStatus: QuickAssistVerificationStatus = .pending,
        verificationConfidence: Double? = nil,
        unsupportedClaimCount: Int? = nil,
        verificationMissingQuestions: [String] = [],
        verificationSuggestedFollowUp: String? = nil,
        policyVersion: String? = nil,
        routeOverride: String? = nil,
        evidencePackManifest: String? = nil,
        userFeedbackStatus: QuickAssistTurnFeedbackStatus = .none,
        userFeedbackNote: String? = nil,
        userFeedbackAt: Date? = nil,
        experimentGroupId: String? = nil,
        candidateLabel: String? = nil,
        baseTurnId: String? = nil,
        candidateRole: QuickAssistCandidateRole? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.threadId = threadId ?? sessionId
        self.turnId = turnId ?? UUID().uuidString
        self.provider = provider
        self.model = model
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationMs = durationMs
        self.isFollowUp = isFollowUp
        self.transcriptLength = transcriptLength
        self.hasScreenshot = hasScreenshot
        self.hasPreviousResponse = hasPreviousResponse
        self.responseLength = responseLength
        self.status = status
        self.errorMessage = errorMessage
        self.transcriptText = transcriptText
        self.question = question
        self.extraContext = extraContext
        self.requestPayload = requestPayload
        self.responseText = responseText
        self.rawResponseText = rawResponseText
        self.guardedResponseText = guardedResponseText
        self.previousResponse = previousResponse
        self.contextMode = contextMode
        self.modelTier = modelTier
        self.questionSource = questionSource
        self.routeConfidence = routeConfidence
        self.verificationStatus = verificationStatus
        self.verificationConfidence = verificationConfidence
        self.unsupportedClaimCount = unsupportedClaimCount
        self.verificationMissingQuestions = verificationMissingQuestions
        self.verificationSuggestedFollowUp = verificationSuggestedFollowUp
        self.policyVersion = policyVersion
        self.routeOverride = routeOverride
        self.evidencePackManifest = evidencePackManifest
        self.userFeedbackStatus = userFeedbackStatus
        self.userFeedbackNote = userFeedbackNote
        self.userFeedbackAt = userFeedbackAt
        self.experimentGroupId = experimentGroupId
        self.candidateLabel = candidateLabel
        self.baseTurnId = baseTurnId
        self.candidateRole = candidateRole
    }
    
    func withCompletion(
        completedAt: Date = Date(),
        status: String,
        responseLength: Int? = nil,
        errorMessage: String? = nil,
        responseText: String? = nil,
        rawResponseText: String? = nil,
        guardedResponseText: String? = nil
    ) -> QuickAssistCallRecord {
        var copy = self
        copy.completedAt = completedAt
        copy.durationMs = Int((completedAt.timeIntervalSince(startedAt)) * 1000)
        copy.status = status
        copy.responseLength = responseLength
        copy.errorMessage = errorMessage
        copy.responseText = responseText
        copy.rawResponseText = rawResponseText
        copy.guardedResponseText = guardedResponseText
        return copy
    }
}
