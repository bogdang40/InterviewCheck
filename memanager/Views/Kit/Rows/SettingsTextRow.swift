import SwiftUI

/// A labelled text field in the overlay's input chrome. Stacked so long
/// values such as endpoints and deployment names get the whole row.
struct SettingsTextRow<Trailing: View>: View {
    let title: String
    var helper: String? = nil
    let placeholder: String
    @Binding var text: String
    var monospaced: Bool = false
    var onSubmit: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing

    @FocusState private var isFocused: Bool

    init(
        title: String,
        helper: String? = nil,
        placeholder: String,
        text: Binding<String>,
        monospaced: Bool = false,
        onSubmit: (() -> Void)? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.helper = helper
        self.placeholder = placeholder
        self._text = text
        self.monospaced = monospaced
        self.onSubmit = onSubmit
        self.trailing = trailing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                SettingsRowLabels(title: title, helper: helper)
                Spacer(minLength: DesignTokens.Spacing.sm)
                trailing()
            }
            TextField(placeholder, text: $text)
                .font(monospaced ? OverlayType.mono : OverlayType.body)
                .foregroundStyle(OverlayPalette.textPrimary)
                .focused($isFocused)
                .autocorrectionDisabled()
                .onSubmit { onSubmit?() }
                .overlayField(isFocused: isFocused)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, SettingsRowMetrics.verticalPadding)
    }
}
