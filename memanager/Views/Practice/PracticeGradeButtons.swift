import SwiftUI

/// Again, Hard, Good, Easy as four large buttons, each printing the
/// interval it would schedule and the number key that triggers it. The
/// keys are released while the attempt editor has focus so typing a digit
/// never grades a card.
struct PracticeGradeButtons: View {
    let previews: [PracticeIntervalPreview]
    let shortcutsEnabled: Bool
    let onChoose: (PracticeGradeChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            FieldLabel(text: "How did it go")
            HStack(spacing: DesignTokens.Spacing.sm) {
                ForEach(previews) { preview in
                    button(for: preview)
                }
            }
        }
    }

    private func button(for preview: PracticeIntervalPreview) -> some View {
        Button {
            onChoose(preview.choice)
        } label: {
            VStack(spacing: DesignTokens.Spacing.xxs) {
                Text(preview.choice.title)
                    .font(OverlayType.callout)
                    .foregroundStyle(preview.choice.tone.color)
                Text(preview.label)
                    .font(OverlayType.monoMicro)
                    .foregroundStyle(OverlayPalette.textSecondary)
                KeyCap(shortcut: preview.choice.key)
            }
            .padding(.vertical, DesignTokens.Spacing.sm)
        }
        .buttonStyle(PracticeGradeButtonStyle(tone: preview.choice.tone))
        .keyboardShortcut(shortcut(for: preview.choice))
        .help("\(preview.choice.title): next review in \(preview.label)")
    }

    private func shortcut(for choice: PracticeGradeChoice) -> KeyboardShortcut? {
        guard shortcutsEnabled, let character = choice.key.first else { return nil }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: [])
    }
}
