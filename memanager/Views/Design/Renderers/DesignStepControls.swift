import SwiftUI

/// Previous and Next step buttons with their key caps, plus the hints for
/// the step and section keys. Folds to two rows when the column is narrow.
struct DesignStepControls: View {
    let progress: DesignStepProgress
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.Spacing.md) {
                buttons
                Spacer(minLength: DesignTokens.Spacing.sm)
                hints
            }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                buttons
                hints
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button(action: onPrevious) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                    Text("Previous")
                }
            }
            .buttonStyle(.overlay(.secondary, size: .small))
            .disabled(!progress.hasPrevious)

            Button(action: onNext) {
                HStack(spacing: 5) {
                    Text("Next")
                    Image(systemName: "chevron.right")
                }
            }
            .buttonStyle(.overlay(.primary, size: .small))
            .disabled(!progress.hasNext)
        }
    }

    private var hints: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            KeyHint(label: "Step", shortcut: DesignShortcutHints.step)
            KeyHint(label: "Section", shortcut: DesignShortcutHints.section)
        }
    }
}
