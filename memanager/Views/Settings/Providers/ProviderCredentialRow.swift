import SwiftUI

struct ProviderCredentialRow: View {
    let provider: AIProviderType
    @Binding var draft: AIProviderSettingsDraft
    @ObservedObject private var settings = SettingsManager.shared

    private var key: Binding<String> {
        Binding(get: { draft.apiKey(for: provider) }, set: { value in
            draft.editAPIKey(value, for: provider)
            settings.setApiKey(value, for: provider)
        })
    }

    var body: some View {
        SettingsSecureRow(
            title: "API key",
            helper: "Changes save to the Keychain. Environment and keys.env overrides take precedence.",
            text: key,
            status: SettingsKeyStatus(settings.apiKeyStatus(for: provider))
        )
        switch settings.apiKeyStatus(for: provider) {
        case .unavailable(let message):
            retryRow(message: message, title: "Retry loading") { settings.reloadProviderCredentials() }
        case .saveFailed(let message):
            retryRow(message: message, title: "Retry saving") { settings.setApiKey(key.wrappedValue, for: provider) }
        default: EmptyView()
        }
    }

    private func retryRow(message: String, title: String, action: @escaping () -> Void) -> some View {
        SettingsRow(title: "Keychain", helper: message, layout: .adaptive) {
            Button(title, action: action).buttonStyle(.overlay(.secondary, size: .small))
        }
    }
}
