import SwiftUI

/// A small spinner beside a caption, for inline loading and extraction
/// states that must not take over the surface.
struct ProgressCaption: View {
    let text: String

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
                .lineLimit(1)
        }
    }
}
