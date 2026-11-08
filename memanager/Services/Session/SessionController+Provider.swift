import Foundation

extension SessionController {
    func loadProviderSettings() {
        let providerType = settings.selectedProvider
        let apiKey = settings.apiKey(for: providerType)
        let model = settings.selectedModel(for: providerType)
        let quickAssistModel = settings.quickAssistModel(for: providerType)

        NSLog("[SessionController] Loading provider: type=\(providerType.rawValue), apiKey=\(apiKey.isEmpty ? "EMPTY" : "SET"), model=\(model), quickAssistModel=\(quickAssistModel)")

        let azureConfig: AzureOpenAIConfig? = providerType == .azureOpenAI ? settings.azureOpenAIConfig() : nil
        if let config = azureConfig {
            NSLog("[SessionController] Azure config: endpoint=\(config.endpoint), deployment=\(config.deploymentName), apiVersion=\(config.apiVersion)")
            var missingFields: [String] = []
            if config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                missingFields.append("endpoint")
            }
            if config.deploymentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                missingFields.append("deploymentName")
            }
            if config.apiVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                missingFields.append("apiVersion")
            }
            if !missingFields.isEmpty {
                NSLog("[SessionController] Azure config missing fields: \(missingFields.joined(separator: ", "))")
            }
        }
        do {
            aiProvider = try AIProviderFactory.create(
                type: providerType,
                apiKey: apiKey,
                model: model,
                quickAssistModel: quickAssistModel,
                reasoningSettings: settings.openAIReasoningSettings(),
                azureConfig: azureConfig
            )
        } catch {
            aiProvider = nil
            errorMessage = error.localizedDescription
            NSLog("[SessionController] Provider creation failed: \(error.localizedDescription)")
        }
        if usesDefaultDebriefComposer {
            debriefComposer = AISessionDebriefComposer(aiProvider: aiProvider)
        }
        NSLog("[SessionController] Provider created: \(aiProvider?.name ?? "nil")")
    }
    func reloadProvider() {
        loadProviderSettings()
    }
    func provider(for type: AIProviderType) -> AIProvider? {
        do {
            return try AIProviderFactory.create(
                type: type,
                apiKey: settings.apiKey(for: type),
                model: settings.selectedModel(for: type),
                quickAssistModel: settings.quickAssistModel(for: type),
                reasoningSettings: settings.openAIReasoningSettings(),
                azureConfig: type == .azureOpenAI ? settings.azureOpenAIConfig() : nil
            )
        } catch {
            logger.logDebugEvent(
                category: "quick_assist",
                name: "experiment_provider_creation_failed",
                details: "type=\(type.rawValue), error=\(error.localizedDescription)"
            )
            return nil
        }
    }
    func logVoiceNormalization(
        surface: VoiceGuardSurface,
        report: VoiceNormalizationReport
    ) {
        self.logger.logDebugEvent(
            category: "voice_guard",
            name: "normalized_\(surface.rawValue)",
            details: "coachingDetected=\(report.coachingDetected), firstPersonBefore=\(report.firstPersonBefore), firstPersonAfter=\(report.firstPersonAfter), rewrites=\(report.rewriteCount)"
        )
    }
    /// Cycle through available AI providers - triggered by Cmd+Shift+/
    /// Only cycles to providers that have valid API keys configured
    func cycleProvider() {
        let allProviders = AIProviderType.allCases
        guard let currentIndex = allProviders.firstIndex(of: settings.selectedProvider) else { return }
        
        // Find next provider with valid API key
        var nextIndex = (currentIndex + 1) % allProviders.count
        var attempts = 0
        
        while attempts < allProviders.count {
            let candidateProvider = allProviders[nextIndex]
            let apiKey = settings.apiKey(for: candidateProvider)
            
            // Check if this provider has a valid API key
            if !apiKey.isEmpty {
                // For Azure, also check that endpoint and deployment are configured
                if candidateProvider == .azureOpenAI {
                    let config = settings.azureOpenAIConfig()
                    if !config.endpoint.isEmpty && !config.deploymentName.isEmpty {
                        settings.selectedProvider = candidateProvider
                        NSLog("[SessionController] Cycled provider to: \(candidateProvider.displayName)")
                        return
                    }
                } else {
                    settings.selectedProvider = candidateProvider
                    NSLog("[SessionController] Cycled provider to: \(candidateProvider.displayName)")
                    return
                }
            }
            
            nextIndex = (nextIndex + 1) % allProviders.count
            attempts += 1
        }
        
        // No valid providers found, stay on current
        NSLog("[SessionController] No other providers with valid API keys configured")
    }
    /// Get current provider display name for status bar
    var currentProviderDisplayName: String {
        let providerName = settings.selectedProvider.displayName
        let modelName = settings.selectedModel(for: settings.selectedProvider)
        // Shorten model name for display
        let shortModel = modelName.replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "-20250514", with: "")
            .replacingOccurrences(of: "-20241022", with: "")
        return "\(providerName) \(shortModel)"
    }
}
