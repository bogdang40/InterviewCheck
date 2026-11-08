import SwiftUI

/// The enrolled voice profile and the switch that puts it to work.
struct VoiceProfileSection: View {
    @ObservedObject var store: VoiceSignatureStore
    let onEnroll: () -> Void
    let onDelete: () -> Void

    private var recognitionHelper: String {
        if store.useSourceBasedIdentification {
            return "Source based identification is selected. This optional profile is used by legacy recognition and the live test."
        }
        if store.isEnabled {
            return "Speech is labelled You or Other by voice."
        }
        if store.hasProfile {
            return "Turn this on to use the enrolled profile for legacy recognition."
        }
        return "Enroll a profile to enable recognition."
    }

    private var profileHelper: String {
        switch store.profileStatus {
        case .loading: return "Loading the stored voice profile."
        case .unavailable(let message): return message
        default: return store.hasProfile
            ? "Your voice signature is ready for recognition."
            : "Optional for source based identification. Required for legacy voice matching."
        }
    }

    var body: some View {
        SettingsSection("Voice profile") {
            SettingsRow(
                title: store.hasProfile ? "Voice profile enrolled" : "Voice profile",
                helper: profileHelper,
                layout: .adaptive
            ) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    ToneBadge(
                        text: store.hasProfile ? "Enrolled" : SettingsKeyStatus(store.profileStatus).badgeText,
                        tone: SettingsKeyStatus(store.profileStatus).tone,
                        systemImage: store.hasProfile ? "waveform.circle.fill" : "waveform.circle"
                    )
                    if store.hasProfile {
                        Button("Enroll again", action: onEnroll)
                            .buttonStyle(.overlay(.secondary, size: .small))
                            .disabled(!store.accessKeyStatus.isConfigured)
                        Button("Delete", action: onDelete)
                            .buttonStyle(.overlay(.destructive, size: .small))
                    } else {
                        Button("Enroll voice", action: onEnroll)
                            .buttonStyle(.overlay(.primary, size: .small))
                            .disabled(!store.accessKeyStatus.isConfigured)
                    }
                }
            }

            if case .unavailable(let message) = store.profileStatus {
                SettingsRow(title: "Keychain", helper: message, layout: .adaptive) {
                    Button("Retry loading") { store.reloadCredentials() }
                        .buttonStyle(.overlay(.secondary, size: .small))
                }
            }

            SettingsToggleRow(
                title: "Voice signature recognition",
                helper: recognitionHelper,
                isOn: $store.isEnabled
            )
            .disabled(!store.hasProfile)
            .opacity(store.hasProfile ? 1 : 0.45)
        }
    }
}
