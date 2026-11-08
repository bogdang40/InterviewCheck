import SwiftUI
import InterviewCheckKit

/// A small window that stays above the video call during an interview:
/// the current question, the latest score, and the two buttons. It is a
/// normal window (title bar, close button) and shows in screen sharing.
struct LiveCompanionView: View {
    @ObservedObject private var controller = InterviewController.shared
    @ObservedObject private var timeline = InterviewTimeline.shared

    private var question: InterviewQuestionRecord? { controller.activeQuestion ?? controller.questions.last }

    var body: some View {
        Group {
            if controller.phase == .live {
                live
            } else {
                ContentUnavailableView {
                    Label("No Interview Running", systemImage: "waveform")
                } description: {
                    Text("Start an interview in the main window. This window then stays above your video call.")
                }
            }
        }
        .floatingWindow()
        .navigationTitle(controller.interview?.candidateName.isEmpty == false ? controller.interview!.candidateName : "Live Companion")
    }

    private var live: some View {
        VStack(alignment: .leading, spacing: 12) {
            AudioStatusStrip(startedAt: nil, compact: true)
            if let question {
                Text("Q\(question.ordinal)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(question.text.isEmpty ? "Listening for the question\u{2026}" : question.text)
                    .font(.headline)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                if let window = controller.activeQuestionID == question.id ? controller.liveWindow : nil {
                    TimingStrip(model: TimingStripModel(
                        window: window,
                        timing: TimingSignal.evaluate(answerWords: window.answerWords, questionEnd: window.questionEnd,
                                                      questionText: question.text),
                        now: timeline.now))
                }
                if let score = controller.scores[question.id] {
                    scoreSummary(score)
                }
            } else {
                Text("Ask a question, then press Question Asked (\u{21E7}\u{2318}\u{21A9}).")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Button("Question Asked") { controller.markQuestion() }
                    .buttonStyle(.borderedProminent)
                Button("Answer Done") { controller.answerDone() }
                    .disabled(controller.activeQuestionID == nil)
            }
            .controlSize(.large)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The current answer's words shared with any AI answer.
    private var sharedWords: SharedWords? {
        guard let question else { return nil }
        let text = controller.activeQuestionID == question.id
            ? (controller.liveWindow?.answerWords.map(\.text).joined(separator: " ") ?? "")
            : question.answerText
        let references = (controller.references[question.id] ?? []).filter { $0.error == nil && !$0.text.isEmpty }
        guard !text.isEmpty, !references.isEmpty else { return nil }
        return SharedWords.anyReference(answer: text, references: references.map(\.text), question: question.text)
    }

    private func scoreSummary(_ score: AnswerScoreRecord) -> some View {
        let band = ScoreBand(percent: score.percent)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(score.percent)%")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(band.color)
                    .monospacedDigit()
                VStack(alignment: .leading) {
                    Text(band.title).font(.subheadline.weight(.semibold))
                    Text(score.isFinal ? "\(score.confidence.rawValue.capitalized) confidence" : "Live estimate")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let reason = score.reasons.first {
                Label(reason, systemImage: "exclamationmark.circle").font(.callout).lineLimit(3)
            }
            if let shared = sharedWords, shared.sharedCount > 0 {
                Label {
                    Text("\(shared.sharedCount) of \(shared.answerCount) words match an AI answer")
                } icon: {
                    RoundedRectangle(cornerRadius: 2).fill(Palette.marker).frame(width: 12, height: 9)
                }
                .font(.callout)
            }
            if let followUp = score.followUps.first {
                Label("Ask: \(followUp)", systemImage: "arrow.turn.down.right").font(.callout).lineLimit(3)
            }
        }
    }
}
