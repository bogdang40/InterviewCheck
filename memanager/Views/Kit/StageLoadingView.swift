import SwiftUI

/// Loading state for a whole surface: a breathing ring, one line about
/// what is happening, an optional context note, and the cancel key.
struct StageLoadingView: View {
    let title: String
    let subtitle: String
    var contextMessage: String? = nil
    var onCancel: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.overlayContentIsVisible) private var isContentVisible

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            ZStack {
                OverlayAmbientAnimation(animation: .easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { phase in
                    Circle()
                        .stroke(OverlayPalette.accentStroke, lineWidth: 2)
                        .frame(width: 52, height: 52)
                        .scaleEffect(reduceMotion ? 1 : phase ? 1.08 : 0.94)
                        .opacity(reduceMotion ? 1 : phase ? 0.5 : 1)
                }
                if isContentVisible {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "hourglass")
                        .accessibilityLabel("Loading")
                }
            }

            VStack(spacing: DesignTokens.Spacing.xs) {
                Text(title)
                    .font(OverlayType.display)
                    .foregroundStyle(OverlayPalette.textPrimary)
                Text(subtitle)
                    .font(OverlayType.body)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if let contextMessage, !contextMessage.isEmpty {
                ToneBanner(tone: .warning, message: contextMessage)
                    .frame(maxWidth: 480)
            }

            if let onCancel {
                Button(action: onCancel) {
                    HStack(spacing: 5) {
                        Text("Cancel")
                        KeyCap(shortcut: ShortcutCatalog.cancelRequest)
                    }
                }
                .buttonStyle(.overlay(.ghost, size: .small))
            }
        }
        .padding(DesignTokens.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
