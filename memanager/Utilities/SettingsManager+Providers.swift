import Foundation

enum OpenAIReasoningSlot: String {
    case solve
    case quick

    var storageKey: String {
        switch self {
        case .solve:
            return "openAISolveReasoningEffort"
        case .quick:
            return "openAIQuickReasoningEffort"
        }
    }
}

extension SettingsManager {
    /// Debug builds talk to a local server; release builds start on the
    /// pinned origin and accept only a loopback override (see AccessServerAddress).
    static let defaultAccessServerBaseURL: String = {
        #if DEBUG
        return "http://localhost:8787"
        #else
        return AccessServerAddress.releaseOrigin
        #endif
    }()
    /// A memory snapshot. Loading and unavailable storage have separate status.
    func apiKey(for provider: AIProviderType) -> String {
        providerCredentials.value(for: provider)
    }

    func apiKeyStatus(for provider: AIProviderType) -> CredentialStatus {
        providerCredentials.status(for: provider)
    }

    func reloadProviderCredentials() { providerCredentials.reload() }

    func setApiKey(_ key: String, for provider: AIProviderType) {
        providerCredentials.save(key, for: provider)
    }

    func selectedModel(for provider: AIProviderType) -> String {
        defaults.string(forKey: keyPrefix + "model.\(provider.rawValue)") ?? defaultModel(for: provider)
    }

    func setSelectedModel(_ model: String, for provider: AIProviderType) {
        defaults.set(model, forKey: keyPrefix + "model.\(provider.rawValue)")
        if provider == .openai {
            normalizeStoredOpenAIReasoningEffortIfNeeded(for: .solve, model: model)
        }
        bumpProviderConfigurationVersion()
    }

    private func defaultModel(for provider: AIProviderType) -> String {
        switch provider {
        case .claude: return "claude-sonnet-5"
        case .openai: return "gpt-5.2"
        case .azureOpenAI: return "gpt-4o"
        }
    }

    // MARK: - Quick Assist Model (Faster models for quick responses)

    func quickAssistModel(for provider: AIProviderType) -> String {
        defaults.string(forKey: keyPrefix + "quickAssistModel.\(provider.rawValue)") ?? defaultQuickAssistModel(for: provider)
    }

    func setQuickAssistModel(_ model: String, for provider: AIProviderType) {
        defaults.set(model, forKey: keyPrefix + "quickAssistModel.\(provider.rawValue)")
        NSLog("[SettingsManager] Quick Assist model for \(provider.rawValue) updated: \(model)")
        if provider == .openai {
            normalizeStoredOpenAIReasoningEffortIfNeeded(for: .quick, model: model)
        }
        bumpProviderConfigurationVersion()
    }

    func openAISolveReasoningEffort(forModel model: String? = nil) -> OpenAIReasoningEffort {
        openAIReasoningEffort(for: .solve, modelOverride: model)
    }

    func setOpenAISolveReasoningEffort(_ effort: OpenAIReasoningEffort, forModel model: String? = nil) {
        setOpenAIReasoningEffort(effort, for: .solve, modelOverride: model)
    }

    func openAIQuickReasoningEffort(forModel model: String? = nil) -> OpenAIReasoningEffort {
        openAIReasoningEffort(for: .quick, modelOverride: model)
    }

    func setOpenAIQuickReasoningEffort(_ effort: OpenAIReasoningEffort, forModel model: String? = nil) {
        setOpenAIReasoningEffort(effort, for: .quick, modelOverride: model)
    }

    func openAIReasoningSettings() -> OpenAIReasoningSettings {
        OpenAIReasoningSettings(
            primaryModelEffort: openAISolveReasoningEffort(),
            quickModelEffort: openAIQuickReasoningEffort()
        )
    }

    func shouldApplyVoiceGuard(for provider: AIProviderType) -> Bool {
        guard provider == .openai else { return true }
        return openAIVoiceGuardEnabled
    }

    private func defaultQuickAssistModel(for provider: AIProviderType) -> String {
        switch provider {
        case .claude: return "claude-haiku-4-5"  // fastest current Claude tier
        case .openai: return "gpt-5.2"
        case .azureOpenAI: return "gpt-4o-mini"
        }
    }

    static func availableQuickAssistModels(for provider: AIProviderType) -> [String] {
        switch provider {
        case .claude:
            return [
                "claude-haiku-4-5",   // Fastest - recommended for Quick Assist
                "claude-sonnet-5",
                "claude-opus-5"
            ]
        case .openai:
            return [
                "gpt-5.4",
                "gpt-5.2",
                "gpt-5.2-codex",
                "gpt-5",
                "gpt-4o-mini",
                "gpt-4o",
                "gpt-4-turbo"
            ]
        case .azureOpenAI:
            return []  // User specifies deployment name directly
        }
    }

    static func availableModels(for provider: AIProviderType) -> [String] {
        switch provider {
        case .claude:
            return [
                "claude-opus-5",
                "claude-sonnet-5",
                "claude-sonnet-4-6",
                "claude-haiku-4-5"
            ]
        case .openai:
            return [
                "gpt-5.4",
                "gpt-5.2",
                "gpt-5.2-codex",
                "gpt-5",
                "gpt-4o",
                "gpt-4o-mini",
                "gpt-4-turbo",
                "o1-preview",
                "o1-mini"
            ]
        case .azureOpenAI:
            return [] // User specifies deployment name directly
        }
    }

    private func openAIReasoningEffort(
        for slot: OpenAIReasoningSlot,
        modelOverride: String? = nil
    ) -> OpenAIReasoningEffort {
        let model = openAIReasoningModel(for: slot, modelOverride: modelOverride)
        let storageKey = keyPrefix + slot.storageKey
        guard let rawValue = defaults.string(forKey: storageKey) else {
            return .high
        }
        guard let storedEffort = OpenAIReasoningEffort(rawValue: rawValue) else {
            guard OpenAIReasoningEffortResolver.prefersResponsesAPI(for: model),
                  let fallback = OpenAIReasoningEffortResolver.defaultEffort(for: model) else {
                return .high
            }
            defaults.set(fallback.rawValue, forKey: storageKey)
            NSLog("[SettingsManager] Replaced invalid OpenAI reasoning effort '%@' with '%@' for %@ model %@", rawValue, fallback.rawValue, slot.rawValue, model)
            return fallback
        }
        return normalizeOpenAIReasoningEffort(
            storedEffort,
            for: slot,
            model: model,
            persistIfNeeded: true
        )
    }

    private func setOpenAIReasoningEffort(
        _ effort: OpenAIReasoningEffort,
        for slot: OpenAIReasoningSlot,
        modelOverride: String? = nil
    ) {
        let model = openAIReasoningModel(for: slot, modelOverride: modelOverride)
        let storageKey = keyPrefix + slot.storageKey
        let resolvedEffort = normalizeOpenAIReasoningEffort(
            effort,
            for: slot,
            model: model,
            persistIfNeeded: false
        )
        if defaults.string(forKey: storageKey) == resolvedEffort.rawValue {
            return
        }
        defaults.set(resolvedEffort.rawValue, forKey: storageKey)
        bumpProviderConfigurationVersion()
    }

    private func normalizeStoredOpenAIReasoningEffortIfNeeded(
        for slot: OpenAIReasoningSlot,
        model: String
    ) {
        let storageKey = keyPrefix + slot.storageKey
        guard let rawValue = defaults.string(forKey: storageKey),
              let storedEffort = OpenAIReasoningEffort(rawValue: rawValue) else {
            return
        }
        _ = normalizeOpenAIReasoningEffort(
            storedEffort,
            for: slot,
            model: model,
            persistIfNeeded: true
        )
    }

    private func normalizeOpenAIReasoningEffort(
        _ effort: OpenAIReasoningEffort,
        for slot: OpenAIReasoningSlot,
        model: String,
        persistIfNeeded: Bool
    ) -> OpenAIReasoningEffort {
        guard OpenAIReasoningEffortResolver.prefersResponsesAPI(for: model) else {
            return effort
        }
        let resolvedEffort = OpenAIReasoningEffortResolver.resolve(
            storedEffort: effort,
            for: model,
            logContext: "settings.\(slot.rawValue)"
        )
        if persistIfNeeded, resolvedEffort != effort {
            defaults.set(resolvedEffort.rawValue, forKey: keyPrefix + slot.storageKey)
        }
        return resolvedEffort
    }

    private func openAIReasoningModel(
        for slot: OpenAIReasoningSlot,
        modelOverride: String?
    ) -> String {
        if let modelOverride {
            return modelOverride
        }
        switch slot {
        case .solve:
            return selectedModel(for: .openai)
        case .quick:
            return quickAssistModel(for: .openai)
        }
    }

}
