import SwiftUI
import InterviewCheckKit

/// The live interview: mark questions, watch AI answers stream in, see the
/// candidate's answer timed and scored.
struct InterviewLiveScreen: View {
    @ObservedObject var controller: InterviewController
    @ObservedObject var timeline: InterviewTimeline
    /// Off for the demo, which has no audio.
    var showsAudioStatus = true
    @ObservedObject private var roles = RoleStore.shared
    @Environment(\.openWindow) private var openWindow
    @State private var editingID: String?
    @State private var editedText = ""

    private var planned: [PlannedQuestion] { roles.role(id: controller.interview?.workspaceID)?.plannedQuestions ?? [] }
    private var focusQuestion: InterviewQuestionRecord? { controller.activeQuestion ?? controller.questions.last }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if showsAudioStatus { AudioStatusStrip(startedAt: controller.interview?.startedAt) }
                if let message = controller.errorMessage {
                    HStack {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Spacer()
                        Button("Dismiss") { controller.errorMessage = nil }.buttonStyle(.borderless)
                    }
                }
                if timeline.voiceNeedsRepick {
                    Label("The call audio reconnected. Pick the candidate's voice again once more than one voice appears.",
                          systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout).foregroundStyle(.orange)
                }
                if timeline.remoteSpeakers.count > 1 { speakerPicker }
                if !planned.isEmpty { plannedStrip }
                if let question = focusQuestion {
                    questionSection(question)
                } else {
                    ContentUnavailableView {
                        Label("Ask your first question", systemImage: "waveform.badge.mic")
                    } description: {
                        Text("Ask it out loud, then press Question Asked (\u{21E7}\u{2318}\u{21A9}), even while the video call is in front. You'll see what AI tools would answer, and how the candidate's answer compares.")
                    }
                    .padding(.top, 40)
                }
                if controller.questions.count > 1 { earlierQuestions }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(controller.interview.map { $0.candidateName.isEmpty ? "Candidate" : $0.candidateName } ?? "Interview")
        .navigationSubtitle(controller.interview?.roleTitle ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { controller.markQuestion() } label: { Label("Question Asked", systemImage: "questionmark.bubble") }
                    .labelStyle(.titleAndIcon)
                    .help("Question asked (\u{21E7}\u{2318}\u{21A9})")
                Button { controller.answerDone() } label: { Label("Answer Done", systemImage: "checkmark.circle") }
                    .labelStyle(.titleAndIcon)
                    .help("Answer done (\u{21E7}\u{2318}E)")
                    .disabled(controller.activeQuestionID == nil)
                Button { openWindow(id: AppWindowID.companion) } label: { Label("Live Companion", systemImage: "rectangle.on.rectangle") }
                    .help("A small window that stays above the video call")
                Button(role: .destructive) { controller.end() } label: { Label("End Interview", systemImage: "stop.circle") }
                    .help("End the interview and save the report")
            }
        }
    }

    private var speakerPicker: some View {
        Picker("Candidate's voice", selection: $timeline.candidateSpeakerIndex) {
            Text("Everyone on the call").tag(Int?.none)
            ForEach(timeline.remoteSpeakers, id: \.self) { Text("Voice \($0 + 1)").tag(Optional($0)) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 520)
    }

    private var plannedStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PLANNED QUESTIONS \u{00B7} CLICK WHEN YOU ASK ONE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(planned) { question in
                        let asked = controller.questions.contains { $0.text == question.text }
                        Button { controller.markQuestion(planned: question) } label: {
                            Text(question.text).lineLimit(1).frame(maxWidth: 300)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .opacity(asked ? 0.5 : 1)
                        .help(question.strongAnswer.isEmpty ? question.text : "Strong answer: \(question.strongAnswer)")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func questionSection(_ question: InterviewQuestionRecord) -> some View {
        let window = controller.activeQuestionID == question.id ? controller.liveWindow : nil
        questionCard(question)
        QuestionNoteField(questionID: question.id, database: controller.database)
            .id(question.id)
            .frame(maxWidth: 640)
        if let window {
            TimingStrip(model: TimingStripModel(
                window: window,
                timing: TimingSignal.evaluate(answerWords: window.answerWords, questionEnd: window.questionEnd,
                                              questionText: question.text),
                now: timeline.now))
            answerBlock(window.answerWords.map { $0.isFiller ? "(\($0.normalized))" : $0.text }.joined(separator: " "))
        } else if !question.answerText.isEmpty {
            answerBlock(question.answerText)
        }
        if let score = controller.scores[question.id] {
            ScoreCard(score: score)
        } else if question.closedAt != nil, !question.answerText.isEmpty {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Scoring the answer\u{2026}").foregroundStyle(.secondary) }
        }
        let answers = controller.references[question.id] ?? []
        if !answers.isEmpty || controller.referencesInFlight.contains(question.id) {
            SectionCaption("What AI tools would have said")
            ReferenceGrid(answers: answers, bestMatchLabel: controller.scores[question.id]?.metrics.bestMatchLabel)
        }
    }

    private func questionCard(_ question: InterviewQuestionRecord) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Tag(text: "Q\(question.ordinal)", color: .accentColor)
                    if controller.autoMarkedIDs.contains(question.id) {
                        Tag(text: "Marked automatically", color: .secondary)
                            .help("You didn't press Question Asked; the app found this question when the answer began.")
                    }
                    if question.closedAt == nil { Tag(text: "Answering", color: .orange) }
                    Spacer()
                    if editingID == question.id {
                        Button("Cancel") { editingID = nil }
                        Button("Save and Regenerate") {
                            controller.updateQuestionText(id: question.id, text: editedText, regenerate: true)
                            editingID = nil
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Edit") { editedText = question.text; editingID = question.id }
                    }
                }
                if editingID == question.id {
                    TextField("Question", text: $editedText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...5)
                } else {
                    Text(question.text.isEmpty ? "Listening for the question\u{2026}" : question.text)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(question.text.isEmpty ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(6)
        }
    }

    private func answerBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionCaption("Candidate's answer")
            Text(text.isEmpty ? "Waiting for the candidate\u{2026}" : text)
                .font(.body)
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var earlierQuestions: some View {
        GroupBox("Earlier questions") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(controller.questions.reversed().filter { $0.id != focusQuestion?.id }) { question in
                    HStack {
                        Text("Q\(question.ordinal)").monospacedDigit().foregroundStyle(.secondary)
                        Text(question.text.isEmpty ? "(no question text)" : question.text).lineLimit(1)
                        Spacer()
                        if let score = controller.scores[question.id] {
                            Tag(text: "\(score.percent)%", color: ScoreBand(percent: score.percent).color)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

/// After "End": the overall line and what to do next.
struct InterviewSummaryView: View {
    @ObservedObject var controller: InterviewController

    var body: some View {
        let interview = controller.interview
        let scoring = controller.questions.contains { controller.scores[$0.id]?.isFinal != true && !$0.answerText.isEmpty }
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Interview Ended").font(.largeTitle.weight(.semibold))
            if let percent = interview?.overallPercent {
                Text("\(percent)%")
                    .font(.system(size: 48, weight: .semibold, design: .rounded))
                    .foregroundStyle(ScoreBand(percent: percent).color)
                Text("\(ScoreBand(percent: percent).title) overall \u{00B7} \(interview?.flaggedCount ?? 0) of \(interview?.questionCount ?? 0) answers flagged")
                    .foregroundStyle(.secondary)
            } else {
                Text("No answers were scored.").foregroundStyle(.secondary)
            }
            if scoring {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Finishing the last scores\u{2026}") }
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Open Report") { AppNavigation.shared.showReport(interview?.id) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("New Interview") { controller.reset() }
                    .controlSize(.large)
                    .disabled(!controller.pendingScoring.isEmpty)
                    .help(controller.pendingScoring.isEmpty ? "" : "Available once the last scores are saved")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .navigationTitle(interview?.candidateName.isEmpty == false ? interview!.candidateName : "Interview")
    }
}
