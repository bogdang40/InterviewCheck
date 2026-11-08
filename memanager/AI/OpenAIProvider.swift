import Foundation

final class OpenAIProvider: AIProvider {
    let name = "OpenAI"
    let apiKey: String
    let model: String
    let quickAssistModel: String
    let chatCompletionsURL = URL(string: "https://api.openai.com/v1/chat/completions")!
    let responsesURL = URL(string: "https://api.openai.com/v1/responses")!
    let requestExecutor: AIRequestExecutor
    let reasoningSettings: OpenAIReasoningSettings
    let contentAssembler = AIMessageContentAssembler()
    /// Read at request time so live language switching keeps working.
    let preferredLanguage: () -> ProgrammingLanguage

    enum OpenAISurface: String {
        case solve
        case quickAssist = "quick_assist"
        case systemDesign = "system_design"
        case mlGuide = "ml_guide"
    }

    enum RequestMode {
        case responses
        case chatCompletions
    }

    init(
        apiKey: String,
        model: String = "gpt-5.2",
        quickAssistModel: String? = nil,
        reasoningSettings: OpenAIReasoningSettings = .default,
        transport: NetworkTransport = URLSessionNetworkTransport(),
        requestExecutor: AIRequestExecutor? = nil,
        preferredLanguage: @escaping () -> ProgrammingLanguage = { SettingsManager.shared.preferredLanguage }
    ) {
        self.apiKey = apiKey
        self.model = model
        self.quickAssistModel = quickAssistModel ?? model
        self.reasoningSettings = reasoningSettings
        self.requestExecutor = requestExecutor ?? AIRequestExecutor(transport: transport)
        self.preferredLanguage = preferredLanguage
    }

    func complete(context: SessionContext) async throws -> MentorResponse {
        guard !apiKey.isEmpty else {
            throw AIProviderError.invalidAPIKey
        }

        let language = preferredLanguage()
        let systemPrompt = composeOpenAISystemPrompt(
            basePrompt: PromptBuilder.buildSystemPrompt(language: language),
            surface: .solve
        )
        let userContent = buildUserContent(context: context)
        let text = try await requestTextNonStreaming(
            model: model,
            systemPrompt: systemPrompt,
            userContent: userContent,
            profile: .solve,
            surface: .solve
        )
        return MentorResponse.parse(from: text)
    }

    func completeSystemDesign(context: SessionContext) async throws -> MentorResponse {
        guard !apiKey.isEmpty else {
            throw AIProviderError.invalidAPIKey
        }

        let systemPrompt = composeOpenAISystemPrompt(
            basePrompt: PromptBuilder.buildSystemDesignSystemPrompt(),
            surface: .systemDesign
        )
        let userContent = buildSystemDesignUserContent(context: context)
        let text = try await requestTextNonStreaming(
            model: model,
            systemPrompt: systemPrompt,
            userContent: userContent,
            profile: .solve,
            surface: .systemDesign
        )
        return MentorResponse.parse(from: text)
    }

    func completeSystemDesignStreaming(
        context: SessionContext,
        onChunk: @escaping (String) -> Void
    ) async throws -> MentorResponse {
        guard !apiKey.isEmpty else {
            throw AIProviderError.invalidAPIKey
        }

        let systemPrompt = composeOpenAISystemPrompt(
            basePrompt: PromptBuilder.buildSystemDesignSystemPrompt(),
            surface: .systemDesign
        )
        let userContent = buildSystemDesignUserContent(context: context)
        let fullText = try await requestTextStreaming(
            model: model,
            systemPrompt: systemPrompt,
            userContent: userContent,
            profile: .solve,
            surface: .systemDesign,
            onChunk: onChunk
        )
        return MentorResponse.parse(from: fullText)
    }

    func quickAssist(context: QuickAssistContext) async throws -> String {
        guard !apiKey.isEmpty else {
            throw AIProviderError.invalidAPIKey
        }

        let language = preferredLanguage()
        let systemPrompt = composeOpenAISystemPrompt(
            basePrompt: PromptBuilder.buildQuickAssistSystemPrompt(
                language: language,
                contextMode: context.contextMode,
                interactionMode: context.interactionMode
            ),
            surface: .quickAssist
        )
        let userContent = buildQuickAssistContent(context: context)
        let selectedModel = context.modelTier == .deep ? model : quickAssistModel
        return try await requestTextNonStreaming(
            model: selectedModel,
            systemPrompt: systemPrompt,
            userContent: userContent,
            profile: .quickAssist,
            surface: .quickAssist,
            quickAssistTier: context.modelTier
        )
    }

    func quickAssistStreaming(
        context: QuickAssistContext,
        onChunk: @escaping (String) -> Void
    ) async throws {
        guard !apiKey.isEmpty else {
            throw AIProviderError.invalidAPIKey
        }

        let language = preferredLanguage()
        let systemPrompt = composeOpenAISystemPrompt(
            basePrompt: PromptBuilder.buildQuickAssistSystemPrompt(
                language: language,
                contextMode: context.contextMode,
                interactionMode: context.interactionMode
            ),
            surface: .quickAssist
        )
        let userContent = buildQuickAssistContent(context: context)
        let selectedModel = context.modelTier == .deep ? model : quickAssistModel

        _ = try await requestTextStreaming(
            model: selectedModel,
            systemPrompt: systemPrompt,
            userContent: userContent,
            profile: .quickAssist,
            surface: .quickAssist,
            quickAssistTier: context.modelTier,
            onChunk: onChunk
        )
    }

    func completeStreaming(
        context: SessionContext,
        onChunk: @escaping (String) -> Void
    ) async throws -> MentorResponse {
        guard !apiKey.isEmpty else {
            throw AIProviderError.invalidAPIKey
        }

        let language = preferredLanguage()
        let systemPrompt = composeOpenAISystemPrompt(
            basePrompt: PromptBuilder.buildSystemPrompt(language: language),
            surface: .solve
        )
        let userContent = buildUserContent(context: context)
        let fullText = try await requestTextStreaming(
            model: model,
            systemPrompt: systemPrompt,
            userContent: userContent,
            profile: .solve,
            surface: .solve,
            onChunk: onChunk
        )
        return MentorResponse.parse(from: fullText)
    }

    func mlGuideStreaming(
        context: MLGuideContext,
        onChunk: @escaping (String) -> Void
    ) async throws {
        guard !apiKey.isEmpty else {
            throw AIProviderError.invalidAPIKey
        }

        let systemPrompt = composeOpenAISystemPrompt(
            basePrompt: PromptBuilder.buildMLGuideSystemPrompt(),
            surface: .mlGuide
        )
        let userContent = buildMLGuideContent(context: context)
        _ = try await requestTextStreaming(
            model: quickAssistModel,
            systemPrompt: systemPrompt,
            userContent: userContent,
            profile: .mlGuide,
            surface: .mlGuide,
            onChunk: onChunk
        )
    }

    func debrief(context: DebriefContext) async throws -> String {
        guard !apiKey.isEmpty else {
            throw AIProviderError.invalidAPIKey
        }

        let systemPrompt = DebriefPromptBuilder.buildSystemPrompt()
        let userPrompt = DebriefPromptBuilder.buildUserPrompt(context: context)
        let userContent = [OpenAIContentBlock(type: "text", text: userPrompt)]

        return try await requestTextNonStreaming(
            model: quickAssistModel,
            systemPrompt: systemPrompt,
            userContent: userContent,
            profile: .debrief,
            surface: .quickAssist
        )
    }

    func composeOpenAISystemPrompt(
        basePrompt: String,
        surface: OpenAISurface
    ) -> String {
        """
        \(basePrompt)

        OpenAI surface contract (\(surface.rawValue)):
        - Keep the response natural, first-person, and speakable as if I am answering live.
        - Keep full depth and reasoning, but avoid robotic or scripted phrasing.
        - Avoid second-person coaching language directed at the candidate.

        Abbreviation policy (strict):
        - On first mention, expand abbreviations as `Full Term (ABBR)`.
        - Do not introduce unexplained abbreviations, including one-letter shorthand like `E`.
        - If multiple abbreviations appear together (for example `(RS, E)`), expand each one on first use.
        - After first definition, reuse the abbreviation only when it improves clarity.

        Mermaid safety policy:
        - Keep Mermaid syntax valid and parser-safe.
        - For node labels containing spaces, punctuation, slashes, parentheses, or HTML breaks, use quoted labels, for example: `EG["Edge Gateway (EG)"]`.
        - If an abbreviation appears in Mermaid labels, define it on first use with full form.
        """
    }

    func openAIDeveloperPrompt(from systemPrompt: String, surface: OpenAISurface) -> String {
        """
        \(systemPrompt)

        OpenAI-specific execution requirements:
        - Surface: \(surface.rawValue)
        - Follow the output contract and required elements exactly.
        - Keep first-person candidate voice and avoid coaching language.
        - Make the wording sound like natural speech with coherent pacing.
        - Preserve markdown structure and paragraph breaks so bullets/newlines render correctly.
        - Apply abbreviation expansion rules consistently in prose and Mermaid.
        - Keep Mermaid labels parser-safe with quoted labels where needed.
        - If context is visual-only, infer the question and provide the direct solution.
        """
    }

    func buildMLGuideContent(context: MLGuideContext) -> [OpenAIContentBlock] {
        makeContentBlocks(from: contentAssembler.mlGuideContent(context: context))
    }

    func buildQuickAssistContent(context: QuickAssistContext) -> [OpenAIContentBlock] {
        makeContentBlocks(from: contentAssembler.quickAssistContent(context: context))
    }

    func buildUserContent(context: SessionContext) -> [OpenAIContentBlock] {
        makeContentBlocks(from: contentAssembler.solveContent(context: context))
    }

    func buildSystemDesignUserContent(context: SessionContext) -> [OpenAIContentBlock] {
        makeContentBlocks(from: contentAssembler.systemDesignContent(context: context))
    }

    /// Maps provider-neutral content pieces onto OpenAI's wire-format blocks.
    func makeContentBlocks(from pieces: [AIMessageContentPiece]) -> [OpenAIContentBlock] {
        pieces.map { piece in
            switch piece {
            case .imageBase64(let base64Image, let mediaType):
                return OpenAIContentBlock(
                    type: "image_url",
                    image_url: OpenAIImageURL(
                        url: "data:\(mediaType);base64,\(base64Image)"
                    )
                )
            case .text(let text):
                return OpenAIContentBlock(type: "text", text: text)
            }
        }
    }

}
