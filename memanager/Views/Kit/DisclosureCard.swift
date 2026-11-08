import SwiftUI

/// Collapsible card with a header row. The header is the whole hit target
/// so a drawer section can be folded with one click or key press.
struct DisclosureCard<Content: View, Trailing: View>: View {
    let title: String
    var systemImage: String? = nil
    var count: Int? = nil
    var tone: OverlayTone? = nil
    @Binding var isExpanded: Bool
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(
        _ title: String,
        systemImage: String? = nil,
        count: Int? = nil,
        tone: OverlayTone? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.count = count
        self.tone = tone
        self._isExpanded = isExpanded
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
            Button {
                withAnimation(DesignTokens.Motion.sectionExpand) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "chevron.right")
                        .font(OverlayType.symbol(9, weight: .bold))
                        .foregroundStyle(OverlayPalette.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    if let tone {
                        Circle()
                            .fill(tone.color)
                            .frame(width: 6, height: 6)
                    }
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(OverlayType.symbol(11))
                            .foregroundStyle(OverlayPalette.textSecondary)
                    }
                    Text(title)
                        .font(OverlayType.heading)
                        .foregroundStyle(OverlayPalette.textPrimary)
                        .lineLimit(1)
                    if let count {
                        CountBadge(count: count)
                    }
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            trailing().padding(.trailing, DesignTokens.Spacing.md)
            }

            if isExpanded {
                Hairline()
                content()
                    .padding(DesignTokens.Spacing.md)
                    .transition(.opacity)
            }
        }
        .overlayCard(.base)
    }
}
