import SwiftUI

/// A menu dressed as a field: the current choice sits in the input well
/// with a chevron, so pickers line up with the text inputs around them.
struct MenuField<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    var isPlaceholder: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(OverlayType.callout)
                        .foregroundStyle(OverlayPalette.textSecondary)
                }
                Text(title)
                    .font(OverlayType.body)
                    .foregroundStyle(isPlaceholder ? OverlayPalette.textTertiary : OverlayPalette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: DesignTokens.Spacing.xs)
                Image(systemName: "chevron.up.chevron.down")
                    .font(OverlayType.micro)
                    .foregroundStyle(OverlayPalette.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .overlayField()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}
