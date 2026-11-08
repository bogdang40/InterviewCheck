import SwiftUI

/// An action rendered inside a banner.
struct BannerAction: Identifiable {
    let id = UUID()
    let title: String
    var kind: OverlayButtonKind = .secondary
    let action: () -> Void
}

/// Inline banner for errors, warnings, coaching, and status. One tone, one
/// line of message, optional title and actions, optional dismiss.
struct ToneBanner: View {
    let tone: OverlayTone
    var title: String? = nil
    let message: String
    var systemImage: String? = nil
    var actions: [BannerAction] = []
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: systemImage ?? tone.systemImage)
                .font(OverlayType.symbol(12))
                .foregroundStyle(tone == .neutral ? OverlayPalette.textSecondary : tone.color)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                if let title, !title.isEmpty {
                    Text(title)
                        .font(OverlayType.captionStrong)
                        .foregroundStyle(OverlayPalette.textPrimary)
                }
                Text(message)
                    .font(OverlayType.caption)
                    .foregroundStyle(title == nil ? OverlayPalette.textPrimary : OverlayPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !actions.isEmpty {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        ForEach(actions) { action in
                            Button(action.title, action: action.action)
                                .buttonStyle(.overlay(action.kind, size: .small))
                        }
                    }
                    .padding(.top, 3)
                }
            }

            Spacer(minLength: 0)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(OverlayType.symbol(9, weight: .bold))
                        .foregroundStyle(OverlayPalette.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(tone.tint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .stroke(tone.stroke, lineWidth: 1)
        )
    }
}
