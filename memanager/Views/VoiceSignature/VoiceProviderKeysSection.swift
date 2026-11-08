import AppKit
import SwiftUI

/// Deepgram and Picovoice keys with their stored status and console links.
struct VoiceProviderKeysSection: View {
    @ObservedObject var store: VoiceSignatureStore
    @Binding var deepgramApiKey: String
    @Binding var accessKey: String

    private static let deepgramConsole = URL(string: "https://console.deepgram.com/")
    private static let picovoiceConsole = URL(string: "https://console.picovoice.ai/")

    var body: some View {
        SettingsSection(
            "Deepgram",
            footer: "Transcription and diarization use your Deepgram account. Stored credentials are not a successful connection test."
        ) {
            SettingsSecureRow(
                title: "API key",
                helper: "Changes save to the Keychain.",
                placeholder: "Deepgram API key",
                text: $deepgramApiKey,
                status: VoiceKeyStatusMapper.status(for: store.deepgramApiKeyStatus)
            )
            retryRow(store.deepgramApiKeyStatus) { store.saveDeepgramApiKey(deepgramApiKey) }
            consoleRow(title: "Console", helper: "Create or copy a key.", url: Self.deepgramConsole)
        }

        SettingsSection("Picovoice (legacy)", footer: "Only needed for the enrolled voice profile and the live test.") {
            SettingsSecureRow(
                title: "AccessKey",
                placeholder: "Picovoice AccessKey",
                text: $accessKey,
                status: VoiceKeyStatusMapper.status(for: store.accessKeyStatus)
            )
            retryRow(store.accessKeyStatus) { store.saveAccessKey(accessKey) }
            consoleRow(title: "Console", helper: "Create or copy an AccessKey.", url: Self.picovoiceConsole)
        }
    }

    @ViewBuilder
    private func retryRow(_ status: AccessKeyStatus, save: @escaping () -> Void) -> some View {
        switch status {
        case .unavailable(let message):
            SettingsRow(title: "Keychain", helper: message, layout: .adaptive) {
                Button("Retry loading") { store.reloadCredentials() }
                    .buttonStyle(.overlay(.secondary, size: .small))
            }
        case .saveFailed(let message):
            SettingsRow(title: "Keychain", helper: message, layout: .adaptive) {
                Button("Retry saving", action: save)
                    .buttonStyle(.overlay(.secondary, size: .small))
            }
        default: EmptyView()
        }
    }

    private func consoleRow(title: String, helper: String, url: URL?) -> some View {
        SettingsRow(title: title, helper: helper) {
            Button {
                if let url { NSWorkspace.shared.open(url) }
            } label: {
                Label("Open console", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.overlay(.ghost, size: .small))
        }
    }
}

/// Maps the store's key status onto the settings badge vocabulary.
enum VoiceKeyStatusMapper {
    static func status(for status: AccessKeyStatus) -> SettingsKeyStatus {
        switch status {
        case .loading: return .loading
        case .saving: return .saving
        case .unavailable(let message): return .unavailable(message)
        case .configured: return .configured
        case .notConfigured: return .missing
        case .saveFailed(let message): return .failed(message)
        }
    }
}
