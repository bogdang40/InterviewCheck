import Foundation

/// One plain text request to one provider and model: system prompt in,
/// streamed text out. The detector uses it for the reference answers, the
/// judge, and role drafts. Unlike the candidate providers it adds nothing
/// to the system prompt, so each prompt is sent exactly as written.
protocol DetectorTextGenerating {
    var label: String { get }
    func streamText(system: String, user: String, onChunk: @escaping (String) -> Void) async throws -> String
}

extension DetectorTextGenerating {
    func completeText(system: String, user: String) async throws -> String {
        try await streamText(system: system, user: user, onChunk: { _ in })
    }
}

enum DetectorClientError: LocalizedError, Equatable {
    case missingKey(AIProviderType)
    case emptyReply

    var errorDescription: String? {
        switch self {
        case .missingKey(let provider): return "Add a \(provider.displayName) key in Settings to use it."
        case .emptyReply: return "The model returned no text."
        }
    }
}

/// Anthropic Messages API, streamed.
struct ClaudeTextClient: DetectorTextGenerating {
    let apiKey: String
    let model: String
    var maxTokens = 2_000
    var executor = AIRequestExecutor()
    var label: String { "Claude \(DetectorModelNames.short(model))" }

    func streamText(system: String, user: String, onChunk: @escaping (String) -> Void) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(ClaudeStreamRequest(
            model: model, max_tokens: maxTokens, stream: true, system: system,
            messages: [ClaudeMessage(role: "user", content: [ClaudeContentBlock(type: "text", text: user)])]
        ))
        return try await executor.executeStreamingTextRequest(
            request, profile: .quickAssist, chunkPolicy: .batched(),
            lineParser: Self.parseDelta, onChunk: onChunk
        )
    }

    static func parseDelta(_ data: Data) -> String? {
        guard let event = try? JSONDecoder().decode(ClaudeStreamEvent.self, from: data),
              event.type == "content_block_delta", event.delta?.type == "text_delta" else { return nil }
        return event.delta?.text
    }
}

/// OpenAI Chat Completions, streamed.
struct OpenAITextClient: DetectorTextGenerating {
    let apiKey: String
    let model: String
    var executor = AIRequestExecutor()
    var label: String { "GPT \(DetectorModelNames.short(model))" }

    func streamText(system: String, user: String, onChunk: @escaping (String) -> Void) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(OpenAIStreamRequest(
            model: model, max_completion_tokens: nil, stream: true,
            messages: [
                OpenAIMessage(role: "system", content: [OpenAIContentBlock(type: "text", text: system)]),
                OpenAIMessage(role: "user", content: [OpenAIContentBlock(type: "text", text: user)]),
            ]
        ))
        return try await executor.executeStreamingTextRequest(
            request, profile: .quickAssist, chunkPolicy: .batched(),
            lineParser: ChatCompletionsDelta.parse, onChunk: onChunk
        )
    }
}

/// Azure OpenAI chat deployment, streamed.
struct AzureTextClient: DetectorTextGenerating {
    let apiKey: String
    let config: AzureOpenAIConfig
    let deployment: String
    var executor = AIRequestExecutor()
    var label: String { "Azure \(deployment)" }

    /// `https://name.openai.azure.com/openai/deployments/<d>/chat/completions?api-version=<v>`,
    /// tolerating an endpoint pasted with a path or query.
    static func requestURL(endpoint: String, deployment: String, apiVersion: String) -> URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        if let url = URL(string: trimmed), let scheme = url.scheme, let host = url.host {
            base = "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
        }
        let name = deployment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deployment
        return URL(string: "\(base)/openai/deployments/\(name)/chat/completions?api-version=\(apiVersion)")
    }

    func streamText(system: String, user: String, onChunk: @escaping (String) -> Void) async throws -> String {
        guard let url = Self.requestURL(endpoint: config.endpoint, deployment: deployment, apiVersion: config.apiVersion) else {
            throw DetectorClientError.missingKey(.azureOpenAI)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.httpBody = try JSONEncoder().encode(AzureOpenAIStreamRequest(
            max_completion_tokens: nil, stream: true,
            messages: [
                AzureOpenAIMessage(role: "system", content: [AzureOpenAIContentBlock(type: "text", text: system)]),
                AzureOpenAIMessage(role: "user", content: [AzureOpenAIContentBlock(type: "text", text: user)]),
            ]
        ))
        return try await executor.executeStreamingTextRequest(
            request, profile: .quickAssist, chunkPolicy: .batched(),
            lineParser: ChatCompletionsDelta.parse, onChunk: onChunk
        )
    }
}

/// Text from one Chat Completions stream line (OpenAI and Azure share it).
enum ChatCompletionsDelta {
    static func parse(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else { return nil }
        return delta["content"] as? String
    }
}

/// Builds clients from the keys saved in Settings.
enum DetectorTextClientFactory {
    static func make(provider: AIProviderType, model: String, settings: SettingsManager = .shared) throws -> DetectorTextGenerating {
        let key = settings.apiKey(for: provider)
        guard !key.isEmpty else { throw DetectorClientError.missingKey(provider) }
        switch provider {
        case .claude:
            return ClaudeTextClient(apiKey: key, model: model)
        case .openai:
            return OpenAITextClient(apiKey: key, model: model)
        case .azureOpenAI:
            let config = settings.azureOpenAIConfig()
            return AzureTextClient(apiKey: key, config: config,
                                   deployment: model.isEmpty ? config.deploymentName : model)
        }
    }
}

/// OpenAI embeddings for meaning similarity. Optional: without an OpenAI
/// key the detector compares wording only.
struct OpenAIEmbeddingClient {
    let apiKey: String
    var model = "text-embedding-3-small"
    var executor = AIRequestExecutor()

    private struct Body: Encodable {
        let model: String
        let input: [String]
    }

    private struct Reply: Decodable {
        struct Item: Decodable {
            let index: Int
            let embedding: [Double]
        }
        let data: [Item]
    }

    func embed(_ texts: [String]) async throws -> [[Double]] {
        guard !texts.isEmpty else { return [] }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/embeddings")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(Body(model: model, input: texts.map { String($0.prefix(8_000)) }))
        let data = try await executor.executeDataRequest(request, profile: .debrief)
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        return reply.data.sorted { $0.index < $1.index }.map(\.embedding)
    }
}

/// Short display names for model ids ("claude-sonnet-5" → "Sonnet 5").
enum DetectorModelNames {
    static func short(_ model: String) -> String {
        var name = model.replacingOccurrences(of: "claude-", with: "").replacingOccurrences(of: "gpt-", with: "")
        name = name.replacingOccurrences(of: "-", with: " ")
        return name.split(separator: " ").map { part in
            part.first.map { $0.isLetter ? $0.uppercased() + part.dropFirst() : String(part) } ?? ""
        }.joined(separator: " ")
    }
}
