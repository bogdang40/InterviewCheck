import SwiftUI

/// The verbatim opener the candidate delivers immediately while the rest
/// of the answer streams in. The largest text on the stage: one glance,
/// one sentence, one copy button.
struct QuickAssistSayFirstCard: View {
    let opener: String
    let maxWidth: CGFloat
    var bodyFontSize: CGFloat = 14
    var clipboard: QuickAssistTextCopying = QuickAssistClipboard()

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text("SAY FIRST")
                    .font(OverlayType.captionStrong)
                    .tracking(1.1)
                    .foregroundStyle(OverlayPalette.accent)
                Spacer(minLength: 0)
                Button {
                    clipboard.copy(opener)
                    withAnimation(DesignTokens.Motion.focus) { didCopy = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        withAnimation(DesignTokens.Motion.focus) { didCopy = false }
                    }
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.overlayIcon(size: 22, isActive: didCopy, bordered: false))
                .help(didCopy ? "Copied" : "Copy the opener")
                .accessibilityLabel("Copy the opener")
            }
            Text(MarkdownText.makeAttributedString(from: opener, renderMode: .rich))
                .font(QuickAssistSayFirstTypography.font(bodyFontSize: bodyFontSize, availableWidth: maxWidth))
                .foregroundStyle(OverlayPalette.textPrimary)
                .lineSpacing(5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, DesignTokens.Spacing.lg)
        .frame(maxWidth: maxWidth, alignment: .leading)
    }
}
