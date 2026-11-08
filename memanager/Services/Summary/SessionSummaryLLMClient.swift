import Foundation

protocol SessionSummaryLLMCalling {
    func send(systemPrompt: String, userPrompt: String, settings: SettingsManager) async throws -> String
}

/// Lightweight HTTP client that calls the user's active provider for a one shot summary call.
/// Bypasses the full `AIProvider` infrastructure because the summary needs a different prompt
/// shape (JSON only output) and does not require streaming, screenshots, or tool calling.
final class SessionSummaryLLMClient: SessionSummaryLLMCalling {
    enum LLMError: Error, LocalizedError {
        case missingAPIKey(String)
        case httpError(status: Int, body: String)
        case invalidResponse
        case unsupportedProvider(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey(let provider): return "API key missing for provider \(provider)."
            case .httpError(let status, let body): return "HTTP \(status): \(body)"
            case .invalidResponse: return "Provider returned an invalid response."
            case .unsupportedProvider(let name): return "Summary not supported for provider \(name)."
            }
        }
    }

    static let shared = SessionSummaryLLMClient()

    private let session: URLSession
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Send the system + user prompt to the active provider and return raw text output.
    func send(systemPrompt: String, userPrompt: String, settings: SettingsManager = .shared) async throws -> String {
        let providerType = settings.selectedProvider
        let apiKey = settings.apiKey(for: providerType)
        guard !apiKey.isEmpty else {
            throw LLMError.missingAPIKey(providerType.rawValue)
        }
        switch providerType {
        case .claude:
            return try await callClaude(
                apiKey: apiKey,
                model: settings.quickAssistModel(for: .claude),
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
        case .openai:
            return try await callOpenAI(
                apiKey: apiKey,
                model: settings.quickAssistModel(for: .openai),
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
        case .azureOpenAI:
            return try await callAzureOpenAI(
                apiKey: apiKey,
                deployment: settings.quickAssistModel(for: .azureOpenAI),
                config: settings.azureOpenAIConfig(),
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
        }
    }

    // MARK: - Claude

    private func callClaude(apiKey: String, model: String, systemPrompt: String, userPrompt: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2000,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userPrompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        if http.statusCode >= 400 {
            throw LLMError.httpError(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]],
            let first = content.first(where: { ($0["type"] as? String) == "text" }),
            let text = first["text"] as? String
        else {
            throw LLMError.invalidResponse
        }
        return text
    }

    // MARK: - OpenAI

    private func callOpenAI(apiKey: String, model: String, systemPrompt: String, userPrompt: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        if http.statusCode >= 400 {
            throw LLMError.httpError(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw LLMError.invalidResponse
        }
        return content
    }

    // MARK: - Azure OpenAI

    private func callAzureOpenAI(
        apiKey: String,
        deployment: String,
        config: AzureOpenAIConfig,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        let requestBody = AzureSummaryRequest(
            messages: [
                AzureSummaryMessage(
                    role: "system",
                    content: [AzureSummaryContentBlock(type: "text", text: systemPrompt)]
                ),
                AzureSummaryMessage(
                    role: "user",
                    content: [AzureSummaryContentBlock(type: "text", text: userPrompt)]
                )
            ]
        )

        let url = try makeAzureRequestURL(
            endpoint: config.endpoint,
            deployment: deployment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? config.deploymentName
                : deployment,
            apiVersion: config.apiVersion
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        if http.statusCode >= 400 {
            throw LLMError.httpError(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        let azureResponse = try JSONDecoder().decode(AzureSummaryResponse.self, from: data)
        guard let text = azureResponse.choices.first?.message.content else {
            throw LLMError.invalidResponse
        }
        return text
    }

    private func makeAzureRequestURL(
        endpoint: String,
        deployment: String,
        apiVersion: String
    ) throws -> URL {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseEndpoint: String
        if let url = URL(string: trimmedEndpoint), let scheme = url.scheme, let host = url.host {
            var base = "\(scheme)://\(host)"
            if let port = url.port {
                base += ":\(port)"
            }
            baseEndpoint = base
        } else {
            baseEndpoint = trimmedEndpoint.hasSuffix("/") ? String(trimmedEndpoint.dropLast()) : trimmedEndpoint
        }

        guard !baseEndpoint.isEmpty, !deployment.isEmpty else {
            throw LLMError.invalidResponse
        }

        guard let url = URL(
            string: "\(baseEndpoint)/openai/deployments/\(deployment)/chat/completions?api-version=\(apiVersion)"
        ) else {
            throw LLMError.invalidResponse
        }
        return url
    }
}

private struct AzureSummaryRequest: Encodable {
    let max_completion_tokens: Int? = nil
    let messages: [AzureSummaryMessage]
}

private struct AzureSummaryMessage: Encodable {
    let role: String
    let content: [AzureSummaryContentBlock]
}

private struct AzureSummaryContentBlock: Encodable {
    let type: String
    let text: String?
}

private struct AzureSummaryResponse: Decodable {
    let choices: [AzureSummaryChoice]
}

private struct AzureSummaryChoice: Decodable {
    let message: AzureSummaryMessageContent
}

private struct AzureSummaryMessageContent: Decodable {
    let content: String?
}
