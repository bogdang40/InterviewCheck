import Foundation

final class AzureOpenAIProvider: AIProvider {
    let name = "Azure OpenAI"
    let apiKey: String
    let config: AzureOpenAIConfig
    let quickAssistModel: String?
    let requestExecutor: AIRequestExecutor
    let contentAssembler = AIMessageContentAssembler()
    /// Read at request time so live language switching keeps working.
    let preferredLanguage: () -> ProgrammingLanguage

    func makeRequestURL(deployment: String? = nil) throws -> URL {
        let deploymentName = deployment ?? config.deploymentName
        let trimmedEndpoint = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)

        // Validate endpoint format - warn if it contains paths or query strings
        if trimmedEndpoint.contains("?") {
            NSLog("[AzureOpenAIProvider] WARNING: Endpoint contains query string - should be just base URL: \(trimmedEndpoint)")
            DebugNDJSONLogger.shared.log(
                runId: "azure",
                hypothesisId: "H-AZ",
                location: "AzureOpenAIProvider.makeRequestURL",
                message: "azure_endpoint_has_query_string",
                data: ["endpoint": trimmedEndpoint]
            )
        }
        if trimmedEndpoint.contains("/openai/") {
            NSLog("[AzureOpenAIProvider] WARNING: Endpoint contains '/openai/' path - should be just base URL: \(trimmedEndpoint)")
            DebugNDJSONLogger.shared.log(
                runId: "azure",
                hypothesisId: "H-AZ",
                location: "AzureOpenAIProvider.makeRequestURL",
                message: "azure_endpoint_has_path",
                data: ["endpoint": trimmedEndpoint]
            )
        }

        // Extract just the base URL if malformed endpoint was passed
        let baseEndpoint: String
        if let url = URL(string: trimmedEndpoint), let scheme = url.scheme, let host = url.host {
            var base = "\(scheme)://\(host)"
            if let port = url.port {
                base += ":\(port)"
            }
            baseEndpoint = base
            if baseEndpoint != trimmedEndpoint {
                NSLog("[AzureOpenAIProvider] Auto-corrected endpoint: '\(trimmedEndpoint)' -> '\(baseEndpoint)'")
            }
        } else {
            baseEndpoint = trimmedEndpoint.hasSuffix("/") ? String(trimmedEndpoint.dropLast()) : trimmedEndpoint
        }

        let urlString = "\(baseEndpoint)/openai/deployments/\(deploymentName)/chat/completions?api-version=\(config.apiVersion)"
        NSLog("[AzureOpenAIProvider] Building URL: endpoint='\(trimmedEndpoint)', baseEndpoint='\(baseEndpoint)', deployment='\(deploymentName)', apiVersion='\(config.apiVersion)'")
        DebugNDJSONLogger.shared.log(
            runId: "azure",
            hypothesisId: "H-AZ",
            location: "AzureOpenAIProvider.makeRequestURL",
            message: "azure_request_url",
            data: [
                "endpoint": trimmedEndpoint,
                "baseEndpoint": baseEndpoint,
                "deployment": deploymentName,
                "apiVersion": config.apiVersion,
                "finalUrl": urlString
            ]
        )
        guard let url = URL(string: urlString) else {
            NSLog("[AzureOpenAIProvider] ERROR: Invalid URL string: \(urlString)")
            DebugNDJSONLogger.shared.log(
                runId: "azure",
                hypothesisId: "H-AZ",
                location: "AzureOpenAIProvider.makeRequestURL",
                message: "azure_invalid_url",
                data: ["urlString": urlString]
            )
            throw AIProviderError.networkError("Invalid Azure endpoint URL: \(urlString)")
        }
        return url
    }

    init(
        apiKey: String,
        config: AzureOpenAIConfig,
        quickAssistModel: String? = nil,
        transport: NetworkTransport = URLSessionNetworkTransport(),
        requestExecutor: AIRequestExecutor? = nil,
        preferredLanguage: @escaping () -> ProgrammingLanguage = { SettingsManager.shared.preferredLanguage }
    ) {
        self.apiKey = apiKey
        self.config = config
        self.quickAssistModel = quickAssistModel
        self.requestExecutor = requestExecutor ?? AIRequestExecutor(transport: transport)
        self.preferredLanguage = preferredLanguage
        NSLog("[AzureOpenAIProvider] Initialized with endpoint=\(config.endpoint), deployment=\(config.deploymentName), apiVersion=\(config.apiVersion), quickAssistModel=\(quickAssistModel ?? "default")")
    }

    func complete(context: SessionContext) async throws -> MentorResponse {
        NSLog("[AzureOpenAIProvider] complete() called, apiKey isEmpty=\(apiKey.isEmpty)")
        guard !apiKey.isEmpty else {
            NSLog("[AzureOpenAIProvider] ERROR: API key is empty!")
            throw AIProviderError.invalidAPIKey
        }

        let language = preferredLanguage()
        let systemPrompt = PromptBuilder.buildSystemPrompt(language: language)
        let userContent = buildUserContent(context: context)

        let requestBody = AzureOpenAIRequest(
            max_completion_tokens: nil,
            messages: [
                AzureOpenAIMessage(role: "system", content: [AzureOpenAIContentBlock(type: "text", text: systemPrompt)]),
                AzureOpenAIMessage(role: "user", content: userContent)
            ]
        )

        let url = try makeRequestURL()
        NSLog("[AzureOpenAIProvider] Requesting completion: url=\(url.absoluteString)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let data = try await requestExecutor.executeDataRequest(
            request,
            profile: .solve
        )

        let azureResponse = try JSONDecoder().decode(AzureOpenAIResponse.self, from: data)

        guard let text = azureResponse.choices.first?.message.content else {
            throw AIProviderError.parsingError("No content in response")
        }

        return MentorResponse.parse(from: text)
    }
    
    func completeSystemDesign(context: SessionContext) async throws -> MentorResponse {
        NSLog("[AzureOpenAIProvider] completeSystemDesign() called, apiKey isEmpty=\(apiKey.isEmpty)")
        guard !apiKey.isEmpty else {
            NSLog("[AzureOpenAIProvider] ERROR: API key is empty!")
            throw AIProviderError.invalidAPIKey
        }

        let systemPrompt = PromptBuilder.buildSystemDesignSystemPrompt()
        let userContent = buildSystemDesignUserContent(context: context)

        let requestBody = AzureOpenAIRequest(
            max_completion_tokens: nil,
            messages: [
                AzureOpenAIMessage(role: "system", content: [AzureOpenAIContentBlock(type: "text", text: systemPrompt)]),
                AzureOpenAIMessage(role: "user", content: userContent)
            ]
        )

        let url = try makeRequestURL()
        NSLog("[AzureOpenAIProvider] Requesting system design completion: url=\(url.absoluteString)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let data = try await requestExecutor.executeDataRequest(
            request,
            profile: .solve
        )

        let azureResponse = try JSONDecoder().decode(AzureOpenAIResponse.self, from: data)

        guard let text = azureResponse.choices.first?.message.content else {
            throw AIProviderError.parsingError("No content in response")
        }

        return MentorResponse.parse(from: text)
    }
    
    func quickAssist(context: QuickAssistContext) async throws -> String {
        NSLog("[AzureOpenAIProvider] quickAssist() called, apiKey isEmpty=\(apiKey.isEmpty)")
        guard !apiKey.isEmpty else {
            NSLog("[AzureOpenAIProvider] ERROR: API key is empty in quickAssist!")
            throw AIProviderError.invalidAPIKey
        }

        let language = preferredLanguage()
        let systemPrompt = PromptBuilder.buildQuickAssistSystemPrompt(
            language: language,
            contextMode: context.contextMode,
            interactionMode: context.interactionMode
        )
        let userContent = buildQuickAssistContent(context: context)
        let requestBody = AzureOpenAIRequest(
            max_completion_tokens: nil,
            messages: [
                AzureOpenAIMessage(role: "system", content: [AzureOpenAIContentBlock(type: "text", text: systemPrompt)]),
                AzureOpenAIMessage(role: "user", content: userContent)
            ]
        )

        // Use quickAssistModel deployment if configured, otherwise use default
        let url = try makeRequestURL(deployment: quickAssistModel)
        NSLog("[AzureOpenAIProvider] Requesting quickAssist: url=\(url.absoluteString), quickAssistDeployment=\(quickAssistModel ?? "default")")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let data = try await requestExecutor.executeDataRequest(
            request,
            profile: .quickAssist
        )

        let azureResponse = try JSONDecoder().decode(AzureOpenAIResponse.self, from: data)

        guard let text = azureResponse.choices.first?.message.content else {
            throw AIProviderError.parsingError("No content in response")
        }

        return text
    }

    func debrief(context: DebriefContext) async throws -> String {
        guard !apiKey.isEmpty else {
            throw AIProviderError.invalidAPIKey
        }

        let systemPrompt = DebriefPromptBuilder.buildSystemPrompt()
        let userPrompt = DebriefPromptBuilder.buildUserPrompt(context: context)

        let requestBody = AzureOpenAIRequest(
            max_completion_tokens: nil,
            messages: [
                AzureOpenAIMessage(role: "system", content: [AzureOpenAIContentBlock(type: "text", text: systemPrompt)]),
                AzureOpenAIMessage(role: "user", content: [AzureOpenAIContentBlock(type: "text", text: userPrompt)])
            ]
        )

        let url = try makeRequestURL(deployment: quickAssistModel)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let data = try await requestExecutor.executeDataRequest(request, profile: .debrief)
        let azureResponse = try JSONDecoder().decode(AzureOpenAIResponse.self, from: data)

        guard let text = azureResponse.choices.first?.message.content else {
            throw AIProviderError.parsingError("No content in debrief response")
        }

        return text
    }

    func buildMLGuideContent(context: MLGuideContext) -> [AzureOpenAIContentBlock] {
        makeContentBlocks(from: contentAssembler.mlGuideContent(context: context))
    }

    func buildQuickAssistContent(context: QuickAssistContext) -> [AzureOpenAIContentBlock] {
        makeContentBlocks(from: contentAssembler.quickAssistContent(context: context))
    }

    func buildUserContent(context: SessionContext) -> [AzureOpenAIContentBlock] {
        makeContentBlocks(from: contentAssembler.solveContent(context: context))
    }

    func buildSystemDesignUserContent(context: SessionContext) -> [AzureOpenAIContentBlock] {
        // Azure historically attaches system design screenshots as PNG data URLs,
        // unlike the JPEG used everywhere else. Preserved deliberately.
        makeContentBlocks(
            from: contentAssembler.systemDesignContent(context: context, imageMediaType: "image/png")
        )
    }

    /// Maps provider-neutral content pieces onto Azure OpenAI's wire-format blocks.
    func makeContentBlocks(from pieces: [AIMessageContentPiece]) -> [AzureOpenAIContentBlock] {
        pieces.map { piece in
            switch piece {
            case .imageBase64(let base64Image, let mediaType):
                return AzureOpenAIContentBlock(
                    type: "image_url",
                    image_url: AzureOpenAIImageURL(
                        url: "data:\(mediaType);base64,\(base64Image)"
                    )
                )
            case .text(let text):
                return AzureOpenAIContentBlock(type: "text", text: text)
            }
        }
    }

    static func parseStreamDelta(data: Data) -> String? {
        guard let event = try? JSONDecoder().decode(AzureOpenAIStreamEvent.self, from: data),
              let delta = event.choices.first?.delta,
              let content = delta.content else {
            return nil
        }
        return content
    }
}
