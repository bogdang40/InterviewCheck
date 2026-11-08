import Foundation

/// Typed error taxonomy for the AI layer.
///
/// Control flow decisions (retry, Chat Completions fallback) key off typed
/// cases and status codes, never off substrings of human readable messages:
/// upstream wording changes must not silently alter behavior.
enum AIProviderError: LocalizedError {
    case invalidAPIKey
    case networkError(String)
    case parsingError(String)
    case rateLimited
    case unknown(String)
    case httpError(status: Int, apiCode: String?, message: String)
    case responseError(APIResponseError)
    case timeout(stage: TimeoutStage)
    case cancelled

    enum TimeoutStage: String {
        /// URLSession level timeout covering the whole request attempt.
        case request
        /// No stream data arrived within the first byte allowance.
        case firstByte
        /// An active stream went silent for longer than the allowance.
        case interChunk
        /// The stream exceeded its total wall clock budget.
        case total
    }

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "Invalid API key. Please check your settings."
        case .networkError(let message):
            return "Network error: \(message)"
        case .parsingError(let message):
            return "Failed to parse response: \(message)"
        case .rateLimited:
            return "Rate limited. Please wait a moment and try again."
        case .unknown(let message):
            return "Unknown error: \(message)"
        case .httpError(let status, let apiCode, let message):
            if let apiCode {
                return "HTTP \(status) (\(apiCode)): \(message)"
            }
            return "HTTP \(status): \(message)"
        case .responseError(let response):
            let prefix = response.statusCode.map { "HTTP \($0)" } ?? "Provider error"
            let identity = response.code ?? response.type
            return "\(prefix)\(identity.map { " (\($0))" } ?? ""): \(response.message)"
        case .timeout(let stage):
            return "The request timed out (\(stage.rawValue))."
        case .cancelled:
            return "The request was cancelled."
        }
    }
}

/// Only response metadata is retained. Request headers and complete bodies are
/// never attached to an error. Message text is bounded and sanitized by the parser.
struct APIResponseError: Equatable {
    let statusCode: Int?
    let code: String?
    let type: String?
    let parameter: String?
    let message: String
    let retryAfter: TimeInterval?

    var isPermanentLimit: Bool {
        let permanentCodes: Set<String> = [
            "insufficient_quota", "credit_balance_exhausted",
            "organization_spend_limit_exceeded", "project_spend_limit_exceeded",
            "organization_usage_limit_exceeded", "billing_hard_limit_reached"
        ]
        return [code, type].compactMap { $0 }.contains { permanentCodes.contains($0) }
    }
}

/// Configuration problems that must surface to the user instead of crashing.
enum ProviderConfigurationError: LocalizedError {
    case missingAzureConfig

    var errorDescription: String? {
        switch self {
        case .missingAzureConfig:
            return "Azure OpenAI is selected but its configuration is incomplete. Set the endpoint, deployment, and API version in Settings."
        }
    }
}
