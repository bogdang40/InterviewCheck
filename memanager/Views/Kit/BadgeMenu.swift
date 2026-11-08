import SwiftUI

/// A menu whose label is a tone badge, for compact pickers such as a
/// workspace stage or a kind filter. The chevron marks it as interactive.
/// The button menu style with a plain button keeps the label as drawn;
/// the borderless pull down style would reduce it to an icon and a title.
struct BadgeMenu<Content: View>: View {
    let text: String
    var tone: OverlayTone = .neutral
    var systemImage: String? = nil
    var help: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                ToneBadge(text: text, tone: tone, systemImage: systemImage)
                Image(systemName: "chevron.down")
                    .font(OverlayType.micro)
                    .foregroundStyle(OverlayPalette.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help ?? text)
    }
}
