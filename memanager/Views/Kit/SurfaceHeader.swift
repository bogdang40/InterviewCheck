import SwiftUI

/// Consistent header row for surfaces, drawers, and cards: a title with an
/// optional symbol, subtitle, and count, plus trailing controls.
struct SurfaceHeader<Trailing: View>: View {
    let title: String
    var systemImage: String? = nil
    var subtitle: String? = nil
    var count: Int? = nil
    var prominence: Prominence = .title
    @ViewBuilder var trailing: () -> Trailing

    enum Prominence {
        case title
        case heading

        var font: Font {
            switch self {
            case .title: return OverlayType.title
            case .heading: return OverlayType.heading
            }
        }
    }

    init(
        _ title: String,
        systemImage: String? = nil,
        subtitle: String? = nil,
        count: Int? = nil,
        prominence: Prominence = .title,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.count = count
        self.prominence = prominence
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(OverlayType.symbol(prominence == .title ? 13 : 11))
                    .foregroundStyle(OverlayPalette.textSecondary)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text(title)
                        .font(prominence.font)
                        .foregroundStyle(OverlayPalette.textPrimary)
                        .lineLimit(1)
                    if let count {
                        CountBadge(count: count)
                    }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            HStack(spacing: DesignTokens.Spacing.xs) {
                trailing()
            }
        }
        .frame(minHeight: prominence == .title ? 28 : 22)
    }
}
