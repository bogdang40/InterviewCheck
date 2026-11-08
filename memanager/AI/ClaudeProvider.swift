import Foundation

final class ClaudeProvider: AIProvider {
    let name = "Claude"
    private let apiKey: String
    private let model: String
    private let quickAssistModel: String
    private let baseURL = "https://api.anthropic.com/v1/messages"
    private let requestExecutor: AIRequestExecutor
    private let contentAssembler = AIMessageContentAssembler()
    /// Read at request time so live language switching keeps working.
    private let preferredLanguage: () -> ProgrammingLanguage
    /// Anthropic requires `max_tokens` on every request.
    /// We keep this very high by default and allow override via env var.
    private static let defaultMaxTokens = 32_000

    init(
        apiKey: String,
        model: String = "claude-sonnet-5",
        quickAssistModel: String? = nil,
        transport: NetworkTransport = URLSessionNetworkTransport(),
        requestExecutor: AIRequestExecutor? = nil,
        preferredLanguage: @escaping () -> ProgrammingLanguage = { SettingsManager.shared.preferredLanguage }
    ) {
        self.apiKey = apiKey
        self.model = model
        // Use faster model for Quick Assist (Haiku is 3x faster than Sonnet)
        self.quickAssistModel = quickAssistModel ?? "claude-haiku-4-5"
        self.requestExecutor = requestExecutor ?? AIRequestExecutor(transport: transport)
        self.preferredLanguage = preferredLanguage
    }

    /// Builds the standard Anthropic Messages API request: POST with JSON body,
    /// API key, and pinned API version headers.
    private func makeRequest<Body: Encodable>(body: Body) throws -> URLRequest {
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private static func resolvedMaxTokens(requested: Int?) -> Int {
        if let requested, requested > 0 {
            return requested
        }

        if let fromEnv = ProcessInfo.processInfo.environment["MEMANAGER_CLAUDE_MAX_TOKENS"],
           let envValue = Int(fromEnv),
           envValue > 0 {
            return envValue
        }

        return defaultMaxTokens
    }

    func complete(context: SessionContext) async throws -> MentorResponse {
        guard !apiKey.isEmpty else {
            throw AIProviderError.invalidAPIKey
        }

        let language = preferredLanguage()
        let systemPrompt = PromptBuilder.buildSystemPrompt(language: language)
        let userContent = buildUserContent(context: context)

        let requestBody = ClaudeRequest(
            model: model,
            max_tokens: Self.resolvedMaxTokens(requested: nil),
            system: systemPrompt,
            messages: [
                ClaudeMessage(role: "user", content: userContent)
            ]
        )

        let request = try makeRequest(body: requestBody)

        let data = try await requestExecutor.executeDataRequest(
            request,
            profile: .solve
        )

        let claudeResponse = try JSONDecoder().decode(ClaudeResponse.self, from: data)

        guard let textContent = claudeResponse.content.first(where: { $0.type == "text" }),
              let text = textContent.text else {
            throw AIProviderError.parsingError("No text content in response")
        }

        return MentorResponse.parse(from: text)
    }
    
    func completeSystemDesign(context: SessionContext) async throws -> MentorResponse {
        guard !apiKey.isEmpty else {
            throw AIProviderError.invalidAPIKey
        }

        let systemPrompt = PromptBuilder.buildSystemDesignSystemPrompt()
        let userContent = buildSystemDesignUserContent(context: context)

        let requestBody = ClaudeRequest(
            model: model,
            max_tokens: Self.resolvedMaxTokens(requested: nil),
            system: systemPrompt,
            messages: [
                ClaudeMessage(role: "user", content: userContent)
            ]
        )

        let request = try makeRequest(body: requestBody)

        let data = try await requestExecutor.executeDataRequest(
            request,
            profile: .solve
        )

        let claudeResponse = try JSONDecoder().decode(ClaudeResponse.self, from: data)

        guard let textContent = claudeResponse.content.first(where: { $0.type == "text" }),
              let text = textContent.text else {
            throw AIProviderError.parsingError("No text content in response")
        }

        return MentorResponse.parse(from: text)
    }
    
    func completeSystemDesignStreaming(
        context: SessionContext,
        onChunk: @escaping (String) -> Void
    ) async throws -> MentorResponse {
        guard !apiKey.isEmpty else {
            throw AIProviderError.invalidAPIKey
        }

        let systemPrompt = PromptBuilder.buildSystemDesignSystemPrompt()
        let userContent = buildSystemDesignUserContent(context: context)

        let requestBody = ClaudeStreamRequest(
            model: model,
            max_tokens: Self.resolvedMaxTokens(requested: nil),
            stream: true,
            system: systemPrompt,
            messages: [
                ClaudeMessage(role: "user", content: userContent)
            ]
        )

        let request = try makeRequest(body: requestBody)

        let fullText = try await requestExecutor.executeStreamingTextRequest(
            request,
            profile: .solve,
            chunkPolicy: .immediate,
            lineParser: Self.parseStreamDelta,
            onChunk: onChunk
        )
        return MentorResponse.parse(from: fullText)
    }

    func quickAssist(context: QuickAssistContext) async throws -> String {
        guard !apiKey.isEmpty else {
            throw AIProviderError.invalidAPIKey
        }

        let language = preferredLanguage()
        let systemPrompt = PromptBuilder.buildQuickAssistSystemPrompt(
            language: language,
            contextMode: context.contextMode,
            interactionMode: context.interactionMode
        )
        let userContent = buildQuickAssistContent(context: context)
        // Use faster model for Quick Assist (Haiku is 3x faster than Sonnet)
        let requestBody = ClaudeRequest(
            model: quickAssistModel,
            max_tokens: Self.resolvedMaxTokens(requested: context.tokenBudget),
            system: systemPrompt,
            messages: [
                ClaudeMessage(role: "user", content: userContent)
            ]
        )

        let request = try makeRequest(body: requestBody)

        let data = try await requestExecutor.executeDataRequest(
            request,
            profile: .quickAssist
        )

        let claudeResponse = try JSONDecoder().decode(ClaudeResponse.self, from: data)

        guard let textContent = claudeResponse.content.first(where: { $0.type == "text" }),
              let text = textContent.text else {
            throw AIProviderError.parsingError("No text content in response")
        }

        return text
    }

    func quickAssistStreaming(
        context: QuickAssistContext,
        onChunk: @escaping (String) -> Void
    ) async throws {
        guard !apiKey.isEmpty else {
            throw AIProviderError.invalidAPIKey
        }

        let language = preferredLanguage()
        let systemPrompt = PromptBuilder.buildQuickAssistSystemPrompt(
            language: language,
            contextMode: context.contextMode,
            interactionMode: context.interactionMode
        )
        let userContent = buildQuickAssistContent(context: context)
        // Select model based on tier: deep uses main model, fast uses quickAssistModel
        let selectedModel = context.modelTier == .deep ? model : quickAssistModel
        let requestBody = ClaudeStreamRequest(
            model: selectedModel,
            max_tokens: Self.resolvedMaxTokens(requested: context.tokenBudget),
            stream: true,
            system: systemPrompt,
            messages: [
                ClaudeMessage(role: "user", content: userContent)
            ]
        )

        let request = try makeRequest(body: requestBody)

        _ = try await requestExecutor.executeStreamingTextRequest(
            request,
            profile: .quickAssist,
            chunkPolicy: .batched(),
            lineParser: Self.parseStreamDelta,
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
        let systemPrompt = PromptBuilder.buildSystemPrompt(language: language)
        let userContent = buildUserContent(context: context)
        let requestBody = ClaudeStreamRequest(
            model: model,
            max_tokens: Self.resolvedMaxTokens(requested: nil),
            stream: true,
            system: systemPrompt,
            messages: [
                ClaudeMessage(role: "user", content: userContent)
            ]
        )

        let request = try makeRequest(body: requestBody)

        let fullText = try await requestExecutor.executeStreamingTextRequest(
            request,
            profile: .solve,
            chunkPolicy: .immediate,
            lineParser: Self.parseStreamDelta,
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

        let systemPrompt = PromptBuilder.buildMLGuideSystemPrompt()
        let userContent = buildMLGuideContent(context: context)
        // Use faster model for ML Guide (same as Quick Assist for speed)
        let requestBody = ClaudeStreamRequest(
            model: quickAssistModel,
            max_tokens: Self.resolvedMaxTokens(requested: nil),
            stream: true,
            system: systemPrompt,
            messages: [
                ClaudeMessage(role: "user", content: userContent)
            ]
        )

        let request = try makeRequest(body: requestBody)

        _ = try await requestExecutor.executeStreamingTextRequest(
            request,
            profile: .mlGuide,
            chunkPolicy: .batched(),
            lineParser: Self.parseStreamDelta,
            onChunk: onChunk
        )
    }

    func debrief(context: DebriefContext) async throws -> String {
        guard !apiKey.isEmpty else {
            throw AIProviderError.invalidAPIKey
        }

        let systemPrompt = DebriefPromptBuilder.buildSystemPrompt()
        let userPrompt = DebriefPromptBuilder.buildUserPrompt(context: context)

        let requestBody = ClaudeRequest(
            model: quickAssistModel,
            max_tokens: Self.resolvedMaxTokens(requested: nil),
            system: systemPrompt,
            messages: [
                ClaudeMessage(role: "user", content: [ClaudeContentBlock(type: "text", text: userPrompt)])
            ]
        )

        let request = try makeRequest(body: requestBody)

        let data = try await requestExecutor.executeDataRequest(request, profile: .debrief)
        let claudeResponse = try JSONDecoder().decode(ClaudeResponse.self, from: data)

        guard let textContent = claudeResponse.content.first(where: { $0.type == "text" }),
              let text = textContent.text else {
            throw AIProviderError.parsingError("No text content in debrief response")
        }

        return text
    }

    private func buildMLGuideContent(context: MLGuideContext) -> [ClaudeContentBlock] {
        makeContentBlocks(from: contentAssembler.mlGuideContent(context: context))
    }

    private func buildQuickAssistContent(context: QuickAssistContext) -> [ClaudeContentBlock] {
        makeContentBlocks(from: contentAssembler.quickAssistContent(context: context))
    }

    private func buildUserContent(context: SessionContext) -> [ClaudeContentBlock] {
        makeContentBlocks(from: contentAssembler.solveContent(context: context))
    }

    private func buildSystemDesignUserContent(context: SessionContext) -> [ClaudeContentBlock] {
        makeContentBlocks(from: contentAssembler.systemDesignContent(context: context))
    }

    /// Maps provider-neutral content pieces onto Claude's wire-format blocks.
    private func makeContentBlocks(from pieces: [AIMessageContentPiece]) -> [ClaudeContentBlock] {
        pieces.map { piece in
            switch piece {
            case .imageBase64(let base64Image, let mediaType):
                return ClaudeContentBlock(
                    type: "image",
                    source: ClaudeImageSource(
                        type: "base64",
                        media_type: mediaType,
                        data: base64Image
                    )
                )
            case .text(let text):
                return ClaudeContentBlock(type: "text", text: text)
            }
        }
    }

    private static func parseStreamDelta(data: Data) -> String? {
        guard let event = try? JSONDecoder().decode(ClaudeStreamEvent.self, from: data),
              event.type == "content_block_delta",
              let delta = event.delta,
              delta.type == "text_delta",
              let text = delta.text else {
            return nil
        }
        return text
    }
}
