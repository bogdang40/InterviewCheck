import SwiftUI

/// A titled group of settings rows: heading, optional trailing accessory,
/// an overlay card holding the rows separated by hairlines, and an optional
/// footer sentence in the tertiary tone.
struct SettingsSection<Content: View, Trailing: View>: View {
    let title: String?
    var footer: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(
        _ title: String? = nil,
        footer: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            if title != nil || Trailing.self != EmptyView.self {
                HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
                    if let title {
                        Text(title)
                            .font(OverlayType.heading)
                            .foregroundStyle(OverlayPalette.textPrimary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: DesignTokens.Spacing.sm)
                    trailing()
                }
                .padding(.horizontal, DesignTokens.Spacing.xs)
            }

            SettingsDividedStack {
                content()
            }
            .overlayCard(.base, cornerRadius: DesignTokens.Radius.md)

            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DesignTokens.Spacing.xs)
            }
        }
    }
}
