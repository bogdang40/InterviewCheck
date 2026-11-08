import SwiftUI

/// The live interview: mark questions, watch AI answers stream in, and see
/// the candidate's answer scored.
struct InterviewLiveView: View {
    @ObservedObject var controller: InterviewController
    @ObservedObject var timeline: InterviewTimeline
    let plannedQuestions: [PlannedQuestion]
    let width: CGFloat
    @State private var editedText = ""
    @State private var editingID: String?

    var body: some View {
        VStack(spacing: 0) {
            controls
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    if let message = controller.errorMessage {
                        ToneBanner(tone: .warning, message: message, onDismiss: { controller.errorMessage = nil })
                    }
                    if timeline.remoteSpeakers.count > 1 { speakerPicker }
                    if !plannedQuestions.isEmpty { plannedStrip }
                    if let question = focusQuestion {
                        questionSection(question)
                    } else {
                        OverlayEmptyState(
                            systemImage: "waveform.badge.mic", title: "Ask your first question",
                            message: "Ask it out loud, then press Question asked. The AI answers a cheating tool would show appear here, and the candidate's answer is timed and compared.",
                            hints: [("Question asked", "Cmd+Shift+Return"), ("Answer done", "Cmd+Shift+E")]
                        )
                        .padding(.top, 40)
                    }
                    if controller.questions.count > 1 { earlierQuestions }
                }
                .padding(DesignTokens.Spacing.xl)
            }
        }
    }

    /// The active question, or the latest one after it closes.
    private var focusQuestion: InterviewQuestionRecord? {
        controller.activeQuestion ?? controller.questions.last
    }

    private var controls: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.interview?.candidateName.isEmpty == false ? controller.interview!.candidateName : "Candidate")
                    .font(OverlayType.title)
                    .foregroundStyle(OverlayPalette.textPrimary)
                Text(controller.interview?.roleTitle.isEmpty == false ? controller.interview!.roleTitle : "No role selected")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
            }
            Spacer(minLength: 8)
            Button("Question asked", systemImage: "questionmark.bubble") { controller.markQuestion() }
                .buttonStyle(.overlay(.primary))
                .help("Cmd+Shift+Return")
            Button("Answer done", systemImage: "checkmark") { controller.answerDone() }
                .buttonStyle(.overlay(.secondary))
                .disabled(controller.activeQuestionID == nil)
                .help("Cmd+Shift+E")
            Button("End", systemImage: "stop.fill") { controller.end() }
                .buttonStyle(.overlay(.destructive))
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.vertical, DesignTokens.Spacing.md)
    }

    private var speakerPicker: some View {
        HStack(spacing: 6) {
            FieldLabel(text: "Candidate voice")
            ToggleChip(title: "Everyone remote", isActive: timeline.candidateSpeakerIndex == nil) {
                timeline.candidateSpeakerIndex = nil
            }
            ForEach(timeline.remoteSpeakers, id: \.self) { speaker in
                ToggleChip(title: "Voice \(speaker + 1)", isActive: timeline.candidateSpeakerIndex == speaker) {
                    timeline.candidateSpeakerIndex = speaker
                }
            }
        }
    }

    private var plannedStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: "Planned questions \u{00B7} click when you ask one")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(plannedQuestions) { planned in
                        let asked = controller.questions.contains { $0.text == planned.text }
                        Button { controller.markQuestion(planned: planned) } label: {
                            Text(planned.text).lineLimit(1).frame(maxWidth: 280)
                        }
                        .buttonStyle(.overlay(asked ? .ghost : .secondary, size: .small))
                        .help(planned.strongAnswer.isEmpty ? planned.text : "Strong answer: \(planned.strongAnswer)")
                    }
                }
            }
        }
    }

    @ViewBuilder private func questionSection(_ question: InterviewQuestionRecord) -> some View {
        let window = controller.activeQuestionID == question.id ? controller.liveWindow : nil
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            questionCard(question)
            if let window {
                TimingStripView(model: TimingStripModel(
                    window: window,
                    timing: TimingSignal.evaluate(answerWords: window.answerWords, questionEnd: window.questionEnd,
                                                  questionText: question.text),
                    now: timeline.now))
                answerText(window.answerWords.map { $0.isFiller ? "(\($0.normalized))" : $0.text }.joined(separator: " "))
            } else if !question.answerText.isEmpty {
                answerText(question.answerText)
            }
            if let score = controller.scores[question.id] {
                ScoreCardView(score: score)
            } else if question.closedAt != nil {
                ProgressCaptionRow(text: "Scoring the answer\u{2026}")
            }
            let answers = controller.references[question.id] ?? []
            if !answers.isEmpty || controller.referencesInFlight.contains(question.id) {
                FieldLabel(text: "What AI tools would have said")
                ReferenceAnswerGrid(answers: answers, bestMatchLabel: controller.scores[question.id]?.metrics.bestMatchLabel,
                                    width: width)
            }
        }
    }

    private func questionCard(_ question: InterviewQuestionRecord) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack {
                ToneBadge(text: "Q\(question.ordinal)", tone: .info, monospaced: true)
                if question.closedAt == nil { ToneBadge(text: "Answering", tone: .warning) }
                Spacer(minLength: 0)
                Button(editingID == question.id ? "Save and regenerate" : "Edit") {
                    if editingID == question.id {
                        controller.updateQuestionText(id: question.id, text: editedText, regenerate: true)
                        editingID = nil
                    } else {
                        editedText = question.text
                        editingID = question.id
                    }
                }
                .buttonStyle(.overlay(.ghost, size: .small))
            }
            if editingID == question.id {
                OverlayTextEditor(placeholder: "Type the question", text: $editedText, height: 60)
            } else {
                Text(question.text.isEmpty ? "Listening for the question\u{2026}" : question.text)
                    .font(OverlayType.display)
                    .foregroundStyle(question.text.isEmpty ? OverlayPalette.textTertiary : OverlayPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .overlayCard(.base)
    }

    private func answerText(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(text: "Candidate's answer")
            Text(text.isEmpty ? "Waiting for the candidate\u{2026}" : text)
                .font(OverlayType.body(14))
                .foregroundStyle(text.isEmpty ? OverlayPalette.textTertiary : OverlayPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var earlierQuestions: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: "Earlier questions")
            ForEach(controller.questions.reversed().filter { $0.id != focusQuestion?.id }) { question in
                HStack(spacing: 8) {
                    ToneBadge(text: "Q\(question.ordinal)", monospaced: true)
                    Text(question.text.isEmpty ? "(no question text)" : question.text)
                        .font(OverlayType.body).lineLimit(1)
                        .foregroundStyle(OverlayPalette.textSecondary)
                    Spacer(minLength: 0)
                    if let score = controller.scores[question.id] {
                        ToneBadge(text: "\(score.percent)%", tone: ScoreBand(percent: score.percent).tone, monospaced: true)
                    }
                }
            }
        }
    }
}

/// A spinner with a short caption.
struct ProgressCaptionRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(OverlayType.caption).foregroundStyle(OverlayPalette.textSecondary)
        }
    }
}
