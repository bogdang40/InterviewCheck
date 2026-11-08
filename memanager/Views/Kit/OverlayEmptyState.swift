import SwiftUI

/// An action offered by an empty state, with the key that triggers it.
struct EmptyStateAction: Identifiable {
    let id = UUID()
    let title: String
    var shortcut: String? = nil
    let action: () -> Void
}

/// The overlay's empty state: one symbol, one display line, one sentence,
/// and at most two actions with their key caps.
struct OverlayEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    var primary: EmptyStateAction? = nil
    var secondary: EmptyStateAction? = nil
    var hints: [(label: String, shortcut: String)] = []
    var pulses: Bool = false

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            ZStack {
                OverlayAmbientAnimation(isEnabled: pulses, animation: DesignTokens.Motion.emptyStatePulse) { phase in
                    Circle()
                        .stroke(OverlayPalette.accentStroke, lineWidth: 1.5)
                        .frame(width: 58, height: 58)
                        .scaleEffect(phase ? 1.05 : 1)
                }
                Circle()
                    .fill(OverlayPalette.accentTint)
                    .frame(width: 48, height: 48)
                Image(systemName: systemImage)
                    .font(OverlayType.symbol(22, weight: .medium))
                    .foregroundStyle(OverlayPalette.accent)
            }
            VStack(spacing: DesignTokens.Spacing.xs) {
                Text(title)
                    .font(OverlayType.display)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(OverlayType.body)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }

            if primary != nil || secondary != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DesignTokens.Spacing.sm) { actions }
                    VStack(spacing: DesignTokens.Spacing.sm) { actions }
                }
            }

            if !hints.isEmpty {
                HStack(spacing: DesignTokens.Spacing.md) {
                    ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                        KeyHint(label: hint.label, shortcut: hint.shortcut)
                    }
                }
            }
        }
        .padding(DesignTokens.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var actions: some View {
        if let primary { actionButton(primary, kind: .primary) }
        if let secondary { actionButton(secondary, kind: .ghost) }
    }

    private func actionButton(_ item: EmptyStateAction, kind: OverlayButtonKind) -> some View {
        Button(action: item.action) {
            HStack(spacing: 6) {
                Text(item.title)
                if let shortcut = item.shortcut {
                    KeyCap(shortcut: shortcut, emphasized: kind == .primary)
                }
            }
        }
        .buttonStyle(.overlay(kind))
    }
}
