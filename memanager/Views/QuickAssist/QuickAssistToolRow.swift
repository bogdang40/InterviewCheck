import SwiftUI

/// A labelled row inside a disclosure: title, optional detail line, and
/// trailing controls. Kit candidate: OverlayRow.
struct QuickAssistToolRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    var systemImage: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    init(
        _ title: String,
        detail: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(OverlayType.captionStrong)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(OverlayType.callout)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DesignTokens.Spacing.sm)
            HStack(spacing: DesignTokens.Spacing.xs) {
                trailing()
            }
        }
        .frame(minHeight: 24)
    }
}
