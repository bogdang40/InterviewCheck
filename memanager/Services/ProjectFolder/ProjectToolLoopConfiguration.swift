import Foundation

extension ProjectToolLoopRunner {
    struct Config {
        let providerType: AIProviderType
        let mode: Mode
        let model: String
        let apiKey: String
        let systemPrompt: String
        let userPromptText: String
        let screenshotImagesBase64: [String]
        let rootDescriptor: ProjectToolRootDescriptor
        let promptContract: ProjectToolPromptContract
        let sessionID: UUID?
        let threadID: String?
        let turnID: String?
        let forceTools: Bool
        /// Cumulative answer for the current iteration, empty when an iteration starts.
        let onResponseText: ((String) -> Void)?
        let onToolEvent: (@Sendable (ProjectToolCallEvent) -> Void)?
        let onReasoningEvent: (@Sendable (ProjectToolReasoningEvent) -> Void)?

        init(
            providerType: AIProviderType,
            mode: Mode,
            model: String,
            apiKey: String,
            systemPrompt: String,
            userPromptText: String,
            screenshotImagesBase64: [String],
            rootDescriptor: ProjectToolRootDescriptor,
            promptContract: ProjectToolPromptContract,
            sessionID: UUID?,
            threadID: String?,
            turnID: String?,
            forceTools: Bool = false,
            onToolEvent: (@Sendable (ProjectToolCallEvent) -> Void)? = nil,
            onReasoningEvent: (@Sendable (ProjectToolReasoningEvent) -> Void)? = nil,
            onResponseText: ((String) -> Void)? = nil
        ) {
            self.providerType = providerType
            self.mode = mode
            self.model = model
            self.apiKey = apiKey
            self.systemPrompt = systemPrompt
            self.userPromptText = userPromptText
            self.screenshotImagesBase64 = screenshotImagesBase64
            self.rootDescriptor = rootDescriptor
            self.promptContract = promptContract
            self.sessionID = sessionID
            self.threadID = threadID
            self.turnID = turnID
            self.forceTools = forceTools
            self.onToolEvent = onToolEvent
            self.onReasoningEvent = onReasoningEvent
            self.onResponseText = onResponseText
        }
    }

    struct Result {
        let finalText: String
        let iterationCount: Int
        let toolSummary: [String: Int]
        let reasoningFlow: QuickAssistReasoningFlow
    }

    enum RunError: Error, LocalizedError {
        case notConfigured
        case unsupportedProvider(String)
        case loopCapped(iterations: Int, lastText: String)
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Project folder is not configured for this Mode."
            case .unsupportedProvider(let provider): return "Tool loop is not supported for provider \(provider)."
            case .loopCapped(let n, _): return "Tool loop capped after \(n) iterations."
            case .underlying(let err): return err.localizedDescription
            }
        }
    }
}
