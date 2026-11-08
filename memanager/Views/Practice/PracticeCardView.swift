import SwiftUI

/// One practice card in study order: what was said, the prompt as the one
/// line to read, the attempt editor with the offline grader, the ideal
/// reasoning behind a disclosure, then the four grades.
struct PracticeCardView: View {
    let card: PracticeCard
    let schedule: PracticeSchedule
    var scheduler: PracticeSchedulingAlgorithm = SM2PracticeScheduler()
    let onGrade: (PracticeAttemptEvaluation) -> Void

    @State private var attempt = ""
    @State private var evaluation: PracticeAttemptEvaluation?
    @State private var isIdealRevealed = false
    @State private var isSourceRevealed = false
    @FocusState private var isEditorFocused: Bool

    private let grader = PracticeAttemptGrader()

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            header
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                FieldLabel(text: "Try from memory")
                Text(card.prompt)
                    .font(OverlayType.display)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PracticeAttemptEditor(
                text: $attempt,
                focus: $isEditorFocused,
                evaluation: evaluation,
                onGrade: { evaluation = grader.evaluate(card: card, attemptTranscript: attempt) },
                onRecord: { onGrade($0) }
            )
            DisclosureCard("Source moment", systemImage: "quote.bubble", isExpanded: $isSourceRevealed) {
                PracticeTranscriptQuote(text: card.transcriptSnippet)
            }
            PracticeIdealReveal(text: card.idealReasoning, isRevealed: $isIdealRevealed, shortcutEnabled: !isEditorFocused)
            Hairline()
            PracticeGradeButtons(
                previews: PracticeIntervalPreview.previews(for: schedule, scheduler: scheduler),
                shortcutsEnabled: !isEditorFocused,
                onChoose: recordManualGrade
            )
        }
        .padding(DesignTokens.Spacing.lg)
        .toneEdgeCard(card.difficulty.tone)
        .onChange(of: attempt) { _, _ in evaluation = nil }
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ToneBadge(text: card.topicTag.capitalized, tone: .info, systemImage: "tag")
            ToneBadge(text: card.difficulty.title, tone: card.difficulty.tone, style: .outline)
            Spacer(minLength: 0)
            if schedule.repetitionCount > 0 {
                Text("Review \(schedule.repetitionCount + 1)")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
            }
        }
    }

    private func recordManualGrade(_ choice: PracticeGradeChoice) {
        let trimmed = attempt.trimmingCharacters(in: .whitespacesAndNewlines)
        onGrade(
            PracticeAttemptEvaluation(
                grade: choice.grade,
                confidence: 0,
                feedback: "Graded \(choice.title.lowercased()) by hand.",
                attemptTranscript: trimmed
            )
        )
    }
}
