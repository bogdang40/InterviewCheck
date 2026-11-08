import Foundation

extension AzureOpenAIProvider {
    func completeSystemDesignStreaming(
        context: SessionContext,
        onChunk: @escaping (String) -> Void
    ) async throws -> MentorResponse {
        NSLog("[AzureOpenAIProvider] completeSystemDesignStreaming() called")
        guard !apiKey.isEmpty else {
            throw AIProviderError.invalidAPIKey
        }

        let systemPrompt = PromptBuilder.buildSystemDesignSystemPrompt()
        let userContent = buildSystemDesignUserContent(context: context)

        let requestBody = AzureOpenAIStreamRequest(
            max_completion_tokens: nil,
            stream: true,
            messages: [
                AzureOpenAIMessage(role: "system", content: [AzureOpenAIContentBlock(type: "text", text: systemPrompt)]),
                AzureOpenAIMessage(role: "user", content: userContent)
            ]
        )

        let url = try makeRequestURL()
        NSLog("[AzureOpenAIProvider] Requesting system design streaming: url=\(url.absoluteString)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let fullText = try await requestExecutor.executeStreamingTextRequest(
            request,
            profile: .solve,
            chunkPolicy: .immediate,
            lineParser: Self.parseStreamDelta,
            onChunk: onChunk
        )
        return MentorResponse.parse(from: fullText)
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
        let requestBody = AzureOpenAIStreamRequest(
            max_completion_tokens: context.tokenBudget,
            stream: true,
            messages: [
                AzureOpenAIMessage(role: "system", content: [AzureOpenAIContentBlock(type: "text", text: systemPrompt)]),
                AzureOpenAIMessage(role: "user", content: userContent)
            ]
        )

        // For deep tier, use main deployment; for fast, use quickAssistModel deployment
        let deployment = context.modelTier == .deep ? nil : quickAssistModel
        let url = try makeRequestURL(deployment: deployment)
        NSLog("[AzureOpenAIProvider] Requesting quickAssist stream: url=\(url.absoluteString), tier=\(context.modelTier.rawValue), deployment=\(deployment ?? "default")")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.httpBody = try JSONEncoder().encode(requestBody)

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
        let requestBody = AzureOpenAIStreamRequest(
            max_completion_tokens: nil,
            stream: true,
            messages: [
                AzureOpenAIMessage(role: "system", content: [AzureOpenAIContentBlock(type: "text", text: systemPrompt)]),
                AzureOpenAIMessage(role: "user", content: userContent)
            ]
        )

        let url = try makeRequestURL()
        NSLog("[AzureOpenAIProvider] Requesting completeStreaming: url=\(url.absoluteString)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.httpBody = try JSONEncoder().encode(requestBody)

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
        let requestBody = AzureOpenAIStreamRequest(
            max_completion_tokens: nil,
            stream: true,
            messages: [
                AzureOpenAIMessage(role: "system", content: [AzureOpenAIContentBlock(type: "text", text: systemPrompt)]),
                AzureOpenAIMessage(role: "user", content: userContent)
            ]
        )

        // Use quickAssistModel deployment if configured, otherwise use default
        let url = try makeRequestURL(deployment: quickAssistModel)
        NSLog("[AzureOpenAIProvider] Requesting mlGuide stream: url=\(url.absoluteString)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.httpBody = try JSONEncoder().encode(requestBody)

        _ = try await requestExecutor.executeStreamingTextRequest(
            request,
            profile: .mlGuide,
            chunkPolicy: .batched(),
            lineParser: Self.parseStreamDelta,
            onChunk: onChunk
        )
    }
}
