import Foundation

extension OpenAIProvider {
    func requestTextNonStreaming(
        model: String,
        systemPrompt: String,
        userContent: [OpenAIContentBlock],
        profile: AINetworkSession.SessionProfile,
        surface: OpenAISurface,
        quickAssistTier: QuickAssistModelTier? = nil
    ) async throws -> String {
        let developerPrompt = openAIDeveloperPrompt(from: systemPrompt, surface: surface)

        switch requestMode(for: model) {
        case .responses:
            do {
                return try await executeResponsesNonStreaming(
                    model: model,
                    developerPrompt: developerPrompt,
                    userContent: userContent,
                    profile: profile,
                    reasoning: resolvedReasoning(
                        for: model,
                        surface: surface,
                        quickAssistTier: quickAssistTier
                    )
                )
            } catch {
                guard shouldFallbackToChatCompletions(after: error) else {
                    throw error
                }
                return try await executeChatCompletionsNonStreaming(
                    model: model,
                    systemPrompt: systemPrompt,
                    userContent: userContent,
                    profile: profile
                )
            }
        case .chatCompletions:
            return try await executeChatCompletionsNonStreaming(
                model: model,
                systemPrompt: systemPrompt,
                userContent: userContent,
                profile: profile
            )
        }
    }

    func requestTextStreaming(
        model: String,
        systemPrompt: String,
        userContent: [OpenAIContentBlock],
        profile: AINetworkSession.SessionProfile,
        surface: OpenAISurface,
        quickAssistTier: QuickAssistModelTier? = nil,
        onChunk: @escaping (String) -> Void
    ) async throws -> String {
        let developerPrompt = openAIDeveloperPrompt(from: systemPrompt, surface: surface)

        switch requestMode(for: model) {
        case .responses:
            var emittedChunk = false
            do {
                return try await executeResponsesStreaming(
                    model: model,
                    developerPrompt: developerPrompt,
                    userContent: userContent,
                    profile: profile,
                    surface: surface,
                    reasoning: resolvedReasoning(
                        for: model,
                        surface: surface,
                        quickAssistTier: quickAssistTier
                    )
                ) { chunk in
                    emittedChunk = true
                    onChunk(chunk)
                }
            } catch {
                guard !emittedChunk,
                      shouldFallbackToChatCompletions(after: error) else {
                    throw error
                }
                SessionLogger.shared.logDebugEvent(
                    category: "openai_stream",
                    name: "responses_stream_fallback_to_chat",
                    details: "surface=\(surface.rawValue), model=\(model)"
                )
                return try await executeChatCompletionsStreaming(
                    model: model,
                    systemPrompt: systemPrompt,
                    userContent: userContent,
                    profile: profile,
                    onChunk: onChunk
                )
            }
        case .chatCompletions:
            return try await executeChatCompletionsStreaming(
                model: model,
                systemPrompt: systemPrompt,
                userContent: userContent,
                profile: profile,
                onChunk: onChunk
            )
        }
    }

    func executeChatCompletionsNonStreaming(
        model: String,
        systemPrompt: String,
        userContent: [OpenAIContentBlock],
        profile: AINetworkSession.SessionProfile
    ) async throws -> String {
        let requestBody = OpenAIRequest(
            model: model,
            max_completion_tokens: nil,
            messages: [
                OpenAIMessage(role: "system", content: [OpenAIContentBlock(type: "text", text: systemPrompt)]),
                OpenAIMessage(role: "user", content: userContent)
            ]
        )
        let request = try makeRequest(url: chatCompletionsURL, body: requestBody)
        let data = try await requestExecutor.executeDataRequest(
            request,
            profile: profile
        )
        let response = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let text = response.choices.first?.message.content else {
            throw AIProviderError.parsingError("No content in response")
        }
        return text
    }

    func executeChatCompletionsStreaming(
        model: String,
        systemPrompt: String,
        userContent: [OpenAIContentBlock],
        profile: AINetworkSession.SessionProfile,
        onChunk: @escaping (String) -> Void
    ) async throws -> String {
        let requestBody = OpenAIStreamRequest(
            model: model,
            max_completion_tokens: nil,
            stream: true,
            messages: [
                OpenAIMessage(role: "system", content: [OpenAIContentBlock(type: "text", text: systemPrompt)]),
                OpenAIMessage(role: "user", content: userContent)
            ]
        )
        let request = try makeRequest(url: chatCompletionsURL, body: requestBody)
        return try await requestExecutor.executeStreamingTextRequest(
            request,
            profile: profile,
            chunkPolicy: chunkPolicy(for: profile),
            lineParser: Self.parseStreamDelta,
            onChunk: onChunk
        )
    }

    func makeRequest<T: Encodable>(url: URL, body: T) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    func requestMode(for model: String) -> RequestMode {
        shouldPreferResponsesAPI(for: model) ? .responses : .chatCompletions
    }

    func shouldPreferResponsesAPI(for model: String) -> Bool {
        OpenAIReasoningEffortResolver.prefersResponsesAPI(for: model)
    }

    func resolvedReasoning(
        for model: String,
        surface: OpenAISurface,
        quickAssistTier: QuickAssistModelTier?
    ) -> OpenAIResponsesReasoning? {
        guard shouldPreferResponsesAPI(for: model) else {
            return nil
        }
        let storedEffort: OpenAIReasoningEffort
        switch surface {
        case .quickAssist where quickAssistTier != .deep:
            storedEffort = reasoningSettings.quickModelEffort
        default:
            storedEffort = reasoningSettings.primaryModelEffort
        }
        let effort = OpenAIReasoningEffortResolver.resolve(
            storedEffort: storedEffort,
            for: model,
            logContext: "surface=\(surface.rawValue)"
        )
        return OpenAIResponsesReasoning(effort: effort)
    }

    /// Request shape rejections (4xx from the Responses endpoint) and parse
    /// level failures retarget to Chat Completions. Transport failures, auth
    /// failures, rate limits, timeouts, and cancellation never do: they would
    /// fail identically on the other API.
    static let responsesCompatibilityStatusCodes: Set<Int> = [400, 404, 405, 415, 422]

    func shouldFallbackToChatCompletions(after error: Error) -> Bool {
        guard let providerError = error as? AIProviderError else {
            return false
        }

        switch providerError {
        case .parsingError, .unknown:
            return true
        case .httpError(let status, _, _):
            return Self.responsesCompatibilityStatusCodes.contains(status)
        case .responseError(let response):
            return response.statusCode.map { Self.responsesCompatibilityStatusCodes.contains($0) } ?? false
        case .invalidAPIKey, .rateLimited, .networkError, .timeout, .cancelled:
            return false
        }
    }

    func chunkPolicy(for profile: AINetworkSession.SessionProfile) -> AIStreamChunkPolicy {
        switch profile {
        case .solve, .debrief:
            return .immediate
        case .quickAssist, .mlGuide:
            return .batched()
        }
    }
}
