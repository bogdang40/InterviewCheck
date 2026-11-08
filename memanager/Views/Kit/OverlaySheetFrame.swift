import SwiftUI

/// Chrome shared by every sheet the overlay presents: a title line, an
/// optional explanation, the form, and a footer where Escape cancels and
/// Return confirms, with both keys printed on their buttons.
struct OverlaySheetFrame<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var width: CGFloat = 460
    let primaryTitle: String
    var isPrimaryEnabled: Bool = true
    var busyCaption: String? = nil
    var cancelTitle: String = "Cancel"
    let onPrimary: () -> Void
    let onCancel: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            heading
            content()
            footer
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: width)
        .background(OverlayPalette.canvas)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(title)
                .font(OverlayType.title)
                .foregroundStyle(OverlayPalette.textPrimary)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if let busyCaption {
                ProgressCaption(text: busyCaption)
            }
            Spacer(minLength: 0)
            Button(action: onCancel) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text(cancelTitle)
                    KeyCap(shortcut: "Esc")
                }
            }
            .buttonStyle(.overlayGhost)
            .keyboardShortcut(.cancelAction)

            Button(action: onPrimary) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text(primaryTitle)
                    KeyCap(shortcut: "Return", emphasized: true)
                }
            }
            .buttonStyle(.overlayPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(!isPrimaryEnabled)
        }
    }
}
