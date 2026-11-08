import Foundation

enum OpenAIReasoningEffort: String, CaseIterable, Codable {
    case minimal
    case low
    case medium
    case high
    case xhigh
    case none

    var displayName: String {
        switch self {
        case .xhigh:
            return "X-High"
        case .none:
            return "None"
        default:
            return rawValue.capitalized
        }
    }
}

struct OpenAIReasoningSettings: Equatable {
    let primaryModelEffort: OpenAIReasoningEffort
    let quickModelEffort: OpenAIReasoningEffort

    static let `default` = OpenAIReasoningSettings(
        primaryModelEffort: .high,
        quickModelEffort: .high
    )
}

struct OpenAIReasoningEffortResolver {
    static func prefersResponsesAPI(for model: String) -> Bool {
        profile(for: model) != nil
    }

    static func supportedEfforts(for model: String) -> [OpenAIReasoningEffort] {
        profile(for: model)?.supportedEfforts ?? []
    }

    static func defaultEffort(for model: String) -> OpenAIReasoningEffort? {
        profile(for: model)?.defaultEffort
    }

    static func resolve(
        storedEffort: OpenAIReasoningEffort,
        for model: String,
        logContext: String? = nil
    ) -> OpenAIReasoningEffort {
        guard let profile = profile(for: model) else {
            return storedEffort
        }
        guard !profile.supportedEfforts.contains(storedEffort) else {
            return storedEffort
        }
        let normalized = profile.defaultEffort
        if let logContext {
            OpenAIReasoningNormalizationLog.logOnce(
                key: "\(normalizedModelIdentifier(for: model))|\(storedEffort.rawValue)|\(normalized.rawValue)|\(logContext)",
                message: "[OpenAIReasoningEffortResolver] Normalized unsupported effort '\(storedEffort.rawValue)' to '\(normalized.rawValue)' for model=\(model) (\(logContext))"
            )
        }
        return normalized
    }

    private struct ReasoningProfile {
        let supportedEfforts: [OpenAIReasoningEffort]
        let defaultEffort: OpenAIReasoningEffort
    }

    private static func profile(for model: String) -> ReasoningProfile? {
        let normalized = normalizedModelIdentifier(for: model)
        if normalized.hasPrefix("gpt-5.4") || normalized.hasPrefix("gpt5.4") ||
            normalized.hasPrefix("gpt-5.2") || normalized.hasPrefix("gpt5.2") {
            return ReasoningProfile(
                supportedEfforts: [.none, .low, .medium, .high, .xhigh],
                defaultEffort: .none
            )
        }
        if normalized.hasPrefix("gpt-5") || normalized.hasPrefix("gpt5") {
            return ReasoningProfile(
                supportedEfforts: [.minimal, .low, .medium, .high],
                defaultEffort: .medium
            )
        }
        return nil
    }

    private static func normalizedModelIdentifier(for model: String) -> String {
        model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

private enum OpenAIReasoningNormalizationLog {
    private static let lock = NSLock()
    private static var loggedKeys: Set<String> = []

    static func logOnce(key: String, message: String) {
        lock.lock()
        let inserted = loggedKeys.insert(key).inserted
        lock.unlock()
        guard inserted else { return }
        NSLog("%@", message)
    }
}
