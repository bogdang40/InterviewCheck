import Foundation

extension SettingsManager {
    // MARK: - Azure OpenAI Settings

    func azureEndpoint() -> String {
        let raw = defaults.string(forKey: keyPrefix + "azureEndpoint") ?? ""
        // Auto-sanitize on read to fix any malformed stored endpoints
        let sanitized = sanitizeAzureEndpoint(raw)
        if sanitized != raw && !raw.isEmpty {
            defaults.set(sanitized, forKey: keyPrefix + "azureEndpoint")
        }
        return sanitized
    }

    func setAzureEndpoint(_ endpoint: String) {
        let sanitized = sanitizeAzureEndpoint(endpoint)
        defaults.set(sanitized, forKey: keyPrefix + "azureEndpoint")
        bumpProviderConfigurationVersion()
    }

    /// Extracts just the base URL (scheme + host + optional port) from an Azure endpoint.
    /// This fixes cases where users paste a full URL with path/query strings.
    func sanitizeAzureEndpoint(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        guard let url = URL(string: trimmed),
              let scheme = url.scheme,
              let host = url.host else {
            // If we can't parse it as a URL, return trimmed version
            return trimmed
        }

        var base = "\(scheme)://\(host)"
        if let port = url.port {
            base += ":\(port)"
        }
        return base
    }

    func azureDeploymentName() -> String {
        defaults.string(forKey: keyPrefix + "azureDeploymentName") ?? ""
    }

    func setAzureDeploymentName(_ name: String) {
        defaults.set(name, forKey: keyPrefix + "azureDeploymentName")
        bumpProviderConfigurationVersion()
    }

    func azureAPIVersion() -> String {
        defaults.string(forKey: keyPrefix + "azureAPIVersion") ?? "2024-02-01"
    }

    func setAzureAPIVersion(_ version: String) {
        defaults.set(version, forKey: keyPrefix + "azureAPIVersion")
        bumpProviderConfigurationVersion()
    }

    func azureOpenAIConfig() -> AzureOpenAIConfig {
        AzureOpenAIConfig(
            endpoint: azureEndpoint(),
            deploymentName: azureDeploymentName(),
            apiVersion: azureAPIVersion()
        )
    }
}
