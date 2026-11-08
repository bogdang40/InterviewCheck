import SwiftUI

/// Server origin, shared by sign in, unreachable, and settings. Editable in
/// debug builds only; release builds show the resolved origin read only.
struct AccessServerField: View {
    @ObservedObject var settings: SettingsManager
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            FieldLabel(text: "Access server")
            if AccessServerAddress.isEditable {
                TextField("https://access.example.com", text: $settings.accessServerBaseURL)
                    .font(OverlayType.mono)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .focused($isFocused)
                    .autocorrectionDisabled()
                    .overlayField(isFocused: isFocused)
            } else {
                Text(AccessServerAddress.current(settings: settings))
                    .font(OverlayType.mono)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .textSelection(.enabled)
            }
        }
    }
}
