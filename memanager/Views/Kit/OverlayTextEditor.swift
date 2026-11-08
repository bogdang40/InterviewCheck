import SwiftUI

/// Multi line editor in the overlay's field chrome, with a placeholder and
/// a fixed height so forms keep their rhythm as text grows.
struct OverlayTextEditor: View {
    let placeholder: String
    @Binding var text: String
    var height: CGFloat = 72
    var font: Font = OverlayType.body

    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundStyle(OverlayPalette.textTertiary)
                    .padding(.leading, DesignTokens.Spacing.xs)
                    .padding(.top, DesignTokens.Spacing.xxs)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(font)
                .foregroundStyle(OverlayPalette.textPrimary)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
        }
        .frame(height: height)
        .overlayField(isFocused: isFocused, verticalPadding: DesignTokens.Spacing.xs)
    }
}
