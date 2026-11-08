import SwiftUI

/// The ideal reasoning, hidden until asked for so the attempt comes first.
/// R reveals it; the key is released while the attempt editor has focus.
struct PracticeIdealReveal: View {
    let text: String
    @Binding var isRevealed: Bool
    var shortcutEnabled: Bool = true

    var body: some View {
        DisclosureCard(
            isRevealed ? "Reference reasoning" : "Reveal reference reasoning",
            systemImage: "lightbulb",
            isExpanded: $isRevealed,
            trailing: {
                KeyCap(shortcut: "R")
            },
            content: {
                Text(text)
                    .font(OverlayType.body)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        )
        .background(
            Button("Reveal reference reasoning") {
                withAnimation(DesignTokens.Motion.sectionExpand) {
                    isRevealed.toggle()
                }
            }
            .keyboardShortcut(shortcutEnabled ? KeyboardShortcut("r", modifiers: []) : nil)
            .opacity(0)
            .accessibilityHidden(true)
        )
    }
}
