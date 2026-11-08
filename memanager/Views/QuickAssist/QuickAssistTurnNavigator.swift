import SwiftUI

/// Chevrons, one dot per turn in its verification tone, and a "3 of 5"
/// counter. Dots are clickable so any turn is one click away.
struct QuickAssistTurnNavigator: View {
    let model: QuickAssistTurnNavigatorModel
    let onSelectTurn: (Int) -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Button(action: onPrevious) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.overlayIcon(size: 22))
            .disabled(model.isPreviousDisabled)
            .help("Previous turn (\(ShortcutCatalog.quickAssistPreviousTurn))")

            dotStrip

            Text(model.label)
                .font(OverlayType.monoMicro)
                .foregroundStyle(OverlayPalette.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()

            Button(action: onNext) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.overlayIcon(size: 22))
            .disabled(model.isNextDisabled)
            .help("Next turn (\(ShortcutCatalog.quickAssistNextTurn))")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Turn \(model.label)")
    }

    private var dotStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(model.turnSummaries) { summary in
                        dot(for: summary)
                            .id(summary.id)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.xs)
            }
            .frame(maxWidth: min(CGFloat(model.count) * 13 + 8, 110))
            .onChange(of: model.effectiveSelected) { _, index in
                guard index < model.count else { return }
                withAnimation(DesignTokens.Motion.turnSwap) {
                    proxy.scrollTo(model.turnSummaries[index].id, anchor: .center)
                }
            }
        }
    }

    private func dot(for summary: QuickAssistTurnSummary) -> some View {
        let isSelected = model.isSelected(summary)
        let tone = model.tone(for: summary)
        return Button {
            onSelectTurn(summary.index)
        } label: {
            Circle()
                .fill(tone == .neutral ? OverlayPalette.textTertiary : tone.color)
                .frame(width: 7, height: 7)
                .overlay(
                    Circle()
                        .stroke(isSelected ? OverlayPalette.textPrimary : .clear, lineWidth: 1.5)
                        .frame(width: 11, height: 11)
                )
                .frame(width: 12, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Turn \(summary.index + 1), \(summary.verificationStatus?.displayLabel ?? "Pending")")
        .animation(DesignTokens.Motion.focus, value: model.effectiveSelected)
    }
}
