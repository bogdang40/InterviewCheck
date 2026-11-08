import SwiftUI

/// Floating chip that names the overlay keyboard focus target and the
/// current selection, so hotkey driven navigation is visible even when
/// the focused element is not on screen.
struct OverlayKeyboardStatusView: View {
    let status: String?

    var body: some View {
        if let status, !status.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "keyboard")
                    .font(OverlayType.symbol(9))
                Text(status)
                    .font(OverlayType.monoMicro)
                    .lineLimit(1)
            }
            .foregroundStyle(OverlayPalette.textSecondary)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background(
                Capsule().fill(OverlayPalette.canvas.opacity(0.7))
            )
            .overlay(Capsule().stroke(OverlayPalette.hairlineStrong, lineWidth: 1))
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}
