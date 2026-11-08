import SwiftUI

/// The Practice screen: the due deck for today, one card at a time, with
/// the session counter and progress in the header. Binds to
/// `PracticeStore.shared` so cards authored after a session appear at once.
struct PracticeStudioView: View {
    @ObservedObject private var store = PracticeStore.shared
    @State private var gradedCount = 0

    private let scheduler = SM2PracticeScheduler()

    private var dueCards: [(card: PracticeCard, schedule: PracticeSchedule)] {
        store.dueCards(on: Date())
    }

    private var progress: PracticeSessionProgress {
        PracticeSessionProgress(graded: gradedCount, due: dueCards.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(DesignTokens.Spacing.md)
            Hairline()
            if let error = store.lastError {
                ToneBanner(tone: .critical, title: "Attempt retained", message: error)
                    .padding(.horizontal, DesignTokens.Spacing.md)
            }
            if let current = dueCards.first {
                ScrollView {
                    PracticeCardView(card: current.card, schedule: current.schedule, scheduler: scheduler) { evaluation in
                        record(evaluation, for: current)
                    }
                    .id(current.card.id)
                    .frame(maxWidth: OverlayLayout.readingColumnMaximum)
                    .frame(maxWidth: .infinity)
                    .padding(DesignTokens.Spacing.md)
                }
            } else {
                OverlayEmptyState(
                    systemImage: "square.stack.3d.up",
                    title: gradedCount > 0 ? "Deck clear for today" : "Nothing due",
                    message: "Finished sessions stock the deck. Cards come back when their interval elapses."
                )
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            SurfaceHeader("Practice", systemImage: "square.stack.3d.up", subtitle: "From your finished sessions") {
                CountPill(value: dueCards.count, label: "due")
                CountPill(value: gradedCount, label: "this visit")
            }
            HStack(spacing: DesignTokens.Spacing.sm) {
                ProgressTrack(progress: progress.fraction, tone: .success)
                Text(progress.label)
                    .font(OverlayType.monoMicro)
                    .foregroundStyle(OverlayPalette.textTertiary)
                    .fixedSize()
            }
        }
    }

    private func record(_ evaluation: PracticeAttemptEvaluation, for pair: (card: PracticeCard, schedule: PracticeSchedule)) {
        let now = Date()
        let review = PracticeReview(
            cardID: pair.card.id,
            reviewedAt: now,
            grade: evaluation.grade,
            selfReportedConfidence: evaluation.confidence == 0 ? nil : evaluation.confidence,
            feedback: evaluation.feedback,
            attemptTranscript: evaluation.attemptTranscript.isEmpty ? nil : evaluation.attemptTranscript
        )
        let updated = scheduler.updated(current: pair.schedule, grade: evaluation.grade, reviewedAt: now)
        guard store.record(review: review, newSchedule: updated) else { return }
        withAnimation(DesignTokens.Motion.turnSwap) {
            gradedCount += 1
        }
    }
}
