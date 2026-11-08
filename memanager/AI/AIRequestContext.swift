import Foundation

enum ContextImageSource: String, Codable {
    case freshScreen = "fresh_screen"
    case capturedStack = "captured_stack"
}

struct ContextImage: Codable {
    let source: ContextImageSource
    let base64: String
}

enum FreshCaptureStatus: String, Codable {
    case success
    case failed
    case skipped
}

struct ContextEnvelope: Codable {
    let images: [ContextImage]
    let freshCaptureStatus: FreshCaptureStatus
    let freshCaptureFailureReason: String?

    var imageCount: Int {
        images.count
    }

    var estimatedPayloadChars: Int {
        images.reduce(0) { $0 + $1.base64.count }
    }

    var manifest: String {
        var lines: [String] = []
        switch freshCaptureStatus {
        case .success:
            lines.append("fresh_capture: success")
        case .failed:
            if let reason = freshCaptureFailureReason, !reason.isEmpty {
                lines.append("fresh_capture: failed (\(reason))")
            } else {
                lines.append("fresh_capture: failed")
            }
        case .skipped:
            lines.append("fresh_capture: skipped")
        }
        lines.append("images_attached: \(imageCount)")
        lines.append("images_order: fresh_screen first (if available), then captured_stack newest_to_oldest")
        lines.append("estimated_image_payload_chars: \(estimatedPayloadChars)")
        return lines.joined(separator: "\n")
    }
}

struct QuickAssistContext {
    let transcript: String
    let screenshots: [String] // Base64 encoded images
    let question: String
    let extraContext: String
    let realtimePrompt: String
    let interactionMode: QuickAssistInteractionMode
    let previousResponse: String?  // For follow-up continuations (Cmd+')
    let contextMode: QuickAssistContextMode
    let outputContract: QuickAssistOutputContract
    let contextEnvelope: ContextEnvelope?
    let conversationHistory: [(role: String, content: String)]
    let complexity: QuickAssistComplexity
    let modelTier: QuickAssistModelTier
    let tokenBudget: Int?
    let solveHistorySummary: String?
    let hubIntent: QuickAssistIntent
    let routeReason: String?
    let intentManifest: String?
    let routeOverrideIntent: QuickAssistIntent?
    let evidencePackManifest: String?
    let capabilityPromptAddendum: String?
    /// Response format contract from a classified interview playbook.
    let answerPlaybookContract: String?
    let retrievedMemorySnippets: [String]

    init(
        transcript: String,
        screenshots: [String],
        question: String,
        extraContext: String,
        realtimePrompt: String,
        interactionMode: QuickAssistInteractionMode = .technical,
        previousResponse: String? = nil,
        contextMode: QuickAssistContextMode = .conversation,
        outputContract: QuickAssistOutputContract = .default,
        contextEnvelope: ContextEnvelope? = nil,
        conversationHistory: [(role: String, content: String)] = [],
        complexity: QuickAssistComplexity = .moderate,
        modelTier: QuickAssistModelTier = .fast,
        tokenBudget: Int? = nil,
        solveHistorySummary: String? = nil,
        hubIntent: QuickAssistIntent = .conversation,
        routeReason: String? = nil,
        intentManifest: String? = nil,
        routeOverrideIntent: QuickAssistIntent? = nil,
        evidencePackManifest: String? = nil,
        capabilityPromptAddendum: String? = nil,
        answerPlaybookContract: String? = nil,
        retrievedMemorySnippets: [String] = []
    ) {
        self.transcript = transcript
        self.screenshots = screenshots
        self.question = question
        self.extraContext = extraContext
        self.realtimePrompt = realtimePrompt
        self.interactionMode = interactionMode
        self.previousResponse = previousResponse
        self.contextMode = contextMode
        self.outputContract = outputContract
        self.contextEnvelope = contextEnvelope
        self.conversationHistory = conversationHistory
        self.complexity = complexity
        self.modelTier = modelTier
        self.tokenBudget = tokenBudget
        self.solveHistorySummary = solveHistorySummary
        self.hubIntent = hubIntent
        self.routeReason = routeReason
        self.intentManifest = intentManifest
        self.routeOverrideIntent = routeOverrideIntent
        self.evidencePackManifest = evidencePackManifest
        self.capabilityPromptAddendum = capabilityPromptAddendum
        self.answerPlaybookContract = answerPlaybookContract
        self.retrievedMemorySnippets = retrievedMemorySnippets
    }
}
