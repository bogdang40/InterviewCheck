import SwiftUI

/// What rides along with the next question, as chips, plus a warning chip
/// when the context pipeline reported a problem.
struct QuickAssistComposerContextChips: View {
    let hints: [QuickAssistComposerContextHint]
    let contextStatusMessage: String?

    private var warning: String? {
        guard let message = contextStatusMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
            return nil
        }
        return message
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                if let warning {
                    ToneBadge(text: "Context", tone: .warning, systemImage: "exclamationmark.triangle")
                        .help(warning)
                }
                ForEach(hints) { hint in
                    ToneBadge(text: hint.label, tone: .neutral, systemImage: hint.iconName, style: .outline)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
