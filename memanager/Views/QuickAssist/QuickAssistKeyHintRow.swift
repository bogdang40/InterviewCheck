import SwiftUI

/// Every Quick Assist shortcut as a key hint, shown when the keyboard
/// toggle in the toolbar is on.
struct QuickAssistKeyHintRow: View {
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Spacing.md) {
                ForEach(Array(QuickAssistKeyHintCatalog.hints.enumerated()), id: \.offset) { _, hint in
                    KeyHint(label: hint.label, shortcut: hint.shortcut)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.xs)
        }
        .scrollBounceBehavior(.basedOnSize)
        .transition(.opacity)
    }
}
