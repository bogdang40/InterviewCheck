import AppKit
import SwiftUI

/// The sign in, paywall, and unreachable steps, rendered inside the stealth
/// overlay in place of the shell until the controller reports access. The
/// overlay has no close box, so the header carries Quit and the footer
/// prints the keys that show or hide the panel.
struct AccessGateView: View {
    @ObservedObject var controller: AccessController

    /// Widest the centered card grows, so a wide overlay keeps a form shape.
    static let cardWidth: CGFloat = 580

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                content
                    .frame(maxWidth: Self.cardWidth)
                    .padding(DesignTokens.Spacing.lg)
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            Hairline()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if controller.serverSnapshot != nil {
                Color.clear.frame(width: 32)
            } else {
                Image("AbleyLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }
            Text("Abley")
                .font(OverlayType.callout)
                .foregroundStyle(OverlayPalette.textPrimary)
            Spacer(minLength: 0)
            Text("Account access")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack(spacing: 6) {
                    Text("Quit")
                    KeyCap(shortcut: ShortcutCatalog.quit)
                }
            }
            .buttonStyle(.overlay(.ghost, size: .small))
            .help("Quit Abley")
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .frame(height: OverlayLayout.commandBarHeight)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .checking:
            AccessCheckingView()
        case .signedOut:
            SignInView(controller: controller)
                .overlayCard(.base, padding: DesignTokens.Spacing.lg)
        case .paywall(let snapshot):
            PaywallView(controller: controller, snapshot: snapshot)
                .overlayCard(.base, padding: DesignTokens.Spacing.lg)
        case .unreachable(let message):
            AccessUnreachableView(controller: controller, message: message)
        case .allowed:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            KeyHint(label: "Show or hide", shortcut: ShortcutCatalog.toggleOverlay)
            KeyHint(label: "Quit", shortcut: ShortcutCatalog.quit)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .frame(height: OverlayLayout.statusBarHeight)
    }
}

/// Shown while the first account check is in flight.
struct AccessCheckingView: View {
    var body: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Text("Checking access")
                .font(OverlayType.title)
                .foregroundStyle(OverlayPalette.textPrimary)
            ProgressView()
                .controlSize(.small)
            Text("Checking your account")
                .font(OverlayType.body)
                .foregroundStyle(OverlayPalette.textSecondary)
            Text("You can hide the overlay while this finishes.")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(DesignTokens.Spacing.xxl)
    }
}
