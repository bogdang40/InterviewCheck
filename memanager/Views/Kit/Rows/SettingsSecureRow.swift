import SwiftUI

/// Whether a stored secret is usable. Drives the badge on a secure row.
enum SettingsKeyStatus: Equatable {
    case loading
    case saving
    case unavailable(String)
    case configured
    case missing
    case failed(String)

    var badgeText: String {
        switch self {
        case .loading: return "Loading"
        case .saving: return "Saving"
        case .unavailable: return "Unavailable"
        case .configured: return "Configured"
        case .missing: return "Missing"
        case .failed: return "Save failed"
        }
    }

    var tone: OverlayTone {
        switch self {
        case .loading, .saving: return .neutral
        case .unavailable: return .warning
        case .configured: return .success
        case .missing: return .warning
        case .failed: return .critical
        }
    }

    var help: String? {
        switch self {
        case .failed(let message), .unavailable(let message): return message
        default: return nil
        }
    }

    init(_ status: CredentialStatus) {
        switch status {
        case .loading: self = .loading
        case .saving: self = .saving
        case .configured: self = .configured
        case .missing: self = .missing
        case .unavailable(let message): self = .unavailable(message)
        case .saveFailed(let message): self = .failed(message)
        }
    }

    /// The status implied by the text alone, for keys with no store status.
    static func inferred(from text: String) -> SettingsKeyStatus {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .missing : .configured
    }
}

/// A masked secret with a status badge and a reveal toggle. Always stacked:
/// keys are long, so the field takes the full row width.
struct SettingsSecureRow: View {
    let title: String
    var helper: String? = nil
    var placeholder: String = "Paste key"
    @Binding var text: String
    var status: SettingsKeyStatus? = nil

    @State private var isRevealed = false
    @FocusState private var isFocused: Bool

    private var resolvedStatus: SettingsKeyStatus {
        status ?? .inferred(from: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                SettingsRowLabels(title: title, helper: helper)
                Spacer(minLength: DesignTokens.Spacing.sm)
                ToneBadge(text: resolvedStatus.badgeText, tone: resolvedStatus.tone)
                    .help(resolvedStatus.help ?? resolvedStatus.badgeText)
            }
            HStack(spacing: DesignTokens.Spacing.sm) {
                field
                    .font(OverlayType.mono)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .focused($isFocused)
                    .autocorrectionDisabled()
                    .overlayField(isFocused: isFocused)
                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.overlayIcon(size: 28, isActive: isRevealed))
                .help(isRevealed ? "Hide the key" : "Reveal the key")
                .accessibilityLabel(isRevealed ? "Hide \(title)" : "Reveal \(title)")
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, SettingsRowMetrics.verticalPadding)
    }

    @ViewBuilder
    private var field: some View {
        if isRevealed {
            TextField(placeholder, text: $text)
        } else {
            SecureField(placeholder, text: $text)
        }
    }
}
