import SwiftUI
import InterviewCheckKit

extension ScoreBand {
    var color: Color {
        switch self {
        case .genuine: return .green
        case .mixed: return .orange
        case .flagged: return .red
        }
    }
}

/// The score for one answer: %, confidence, reasons, and follow-ups.
struct ScoreCard: View {
    let score: AnswerScoreRecord
    var showsFollowUps = true
    /// How this answer differs from the candidate's other answers, if it does.
    var baselineNote: String?

    private var band: ScoreBand { ScoreBand(percent: score.percent) }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("\(score.percent)%")
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(band.color)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(band.title).font(.title3.weight(.semibold))
                        HStack(spacing: 6) {
                            Tag(text: "\(score.confidence.rawValue.capitalized) confidence")
                            if !score.isFinal { Tag(text: "Live estimate") }
                            if score.metrics.timingGap { Tag(text: "Audio gap", color: .orange) }
                        }
                    }
                    Spacer(minLength: 0)
                }
                // One spoken summary instead of five separate pieces.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary)
                if !score.reasons.isEmpty {
                    BulletList(title: "Why", items: score.reasons, symbol: "exclamationmark.circle",
                               color: band == .genuine ? .secondary : band.color)
                }
                if let baselineNote {
                    BulletList(title: "Compared with their other answers", items: [baselineNote],
                               symbol: "person.crop.circle.badge.exclamationmark", color: .orange)
                }
                if !score.counterpoints.isEmpty {
                    BulletList(title: "In their favour", items: score.counterpoints, symbol: "checkmark.circle", color: .green)
                }
                if showsFollowUps && !score.followUps.isEmpty {
                    BulletList(title: "Ask next", items: score.followUps, symbol: "arrow.turn.down.right", color: .accentColor)
                }
                Text("A signal to follow up on, not proof. Ask a follow-up before deciding.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    private var accessibilitySummary: String {
        var parts = ["\(score.percent) percent", band.title, "\(score.confidence.rawValue) confidence"]
        if !score.isFinal { parts.append("live estimate") }
        if score.metrics.timingGap { parts.append("audio gap") }
        return parts.joined(separator: ", ")
    }
}

struct BulletList: View {
    let title: String
    let items: [String]
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Label {
                    Text(item).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
                }
            }
        }
    }
}

/// A small rounded label.
struct Tag: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// Silence, stalling, then the answer, on a time axis.
struct TimingStrip: View {
    let model: TimingStripModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let scale = proxy.size.width / model.duration
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    ForEach(Array(model.segments.enumerated()), id: \.offset) { _, segment in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(color(segment.kind))
                            .frame(width: max(2, CGFloat(min(segment.end, model.duration) - segment.start) * scale))
                            .offset(x: CGFloat(segment.start) * scale)
                    }
                }
            }
            .frame(height: 10)
            .accessibilityHidden(true)
            HStack(spacing: 12) {
                Text(model.summary).font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Group {
                    legend("Silence", .silence)
                    legend("Stalling", .stall)
                    legend("Answer", .speech)
                }
                .accessibilityHidden(true)
            }
        }
    }

    private func legend(_ title: String, _ kind: TimingStripModel.Segment.Kind) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color(kind)).frame(width: 7, height: 7)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func color(_ kind: TimingStripModel.Segment.Kind) -> Color {
        switch kind {
        case .silence: return .orange.opacity(0.7)
        case .stall: return .gray.opacity(0.6)
        case .speech: return .accentColor
        }
    }
}

/// One AI answer, streaming in, with the words the candidate also said
/// highlighted.
struct ReferenceCard: View {
    let answer: ReferenceAnswerRecord
    var isBestMatch = false
    var shared: SharedWords = .none

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Tag(text: answer.promptName, color: .accentColor)
                    if shared.sharedCount > 0 {
                        Tag(text: "\(shared.sharedCount) words match", color: .orange)
                            .help("The candidate said \(shared.sharedCount) of these words in the same order (highlighted).")
                    }
                    Spacer(minLength: 0)
                    if answer.isStreaming {
                        ProgressView().controlSize(.small)
                    } else if let first = answer.firstSentenceSeconds, answer.error == nil {
                        Text("first line after \(ScoreNotes.seconds(first))")
                            .font(.caption).foregroundStyle(.secondary)
                            .help("How long a candidate using this tool would wait before they could start reading.")
                    }
                }
                ScrollView {
                    Group {
                        if answer.text.isEmpty {
                            Text(answer.error == nil ? "Writing\u{2026}" : "No answer").foregroundStyle(.secondary)
                        } else {
                            HighlightedText(text: answer.text, words: shared.reference)
                        }
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 190)
                if let error = answer.error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            .padding(4)
        } label: {
            HStack {
                Text(DetectorModelNames.providerShort(answer.provider, model: answer.model))
                    .font(.headline).lineLimit(1)
                Spacer(minLength: 0)
                if isBestMatch { Tag(text: "Closest match", color: .red) }
            }
        }
    }
}

/// AI answers side by side, as many columns as fit.
struct ReferenceGrid: View {
    let answers: [ReferenceAnswerRecord]
    var bestMatchLabel: String?
    /// The candidate's answer and the question, to highlight shared words.
    var candidateAnswer = ""
    var question = ""

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)],
                  alignment: .leading, spacing: 12) {
            ForEach(answers) { answer in
                ReferenceCard(answer: answer, isBestMatch: bestMatchLabel == answer.label,
                              shared: candidateAnswer.isEmpty ? .none
                                  : SharedWords.find(answer: candidateAnswer, reference: answer.text, question: question))
            }
        }
    }
}

/// Text with some of its words highlighted, the way a plagiarism checker
/// marks copied passages.
struct HighlightedText: View {
    let text: String
    let words: Set<Int>

    var body: some View {
        Text(Self.attributed(text, words: words))
    }

    static let fill = Color.orange.opacity(0.3)

    static func attributed(_ text: String, words: Set<Int>) -> AttributedString {
        var result = AttributedString(text)
        for range in SharedWords.highlightRanges(text, words: words) {
            guard let target = Range(range, in: result) else { continue }
            result[target].backgroundColor = fill
        }
        return result
    }
}

/// The candidate's answer with the words an AI answer also has highlighted,
/// and how many there are.
struct CandidateAnswerBlock: View {
    let text: String
    var references: [ReferenceAnswerRecord] = []
    var question = ""
    var placeholder = "Waiting for the candidate\u{2026}"

    var body: some View {
        let usable = references.filter { $0.error == nil && !$0.text.isEmpty }.map(\.text)
        let shared = SharedWords.anyReference(answer: text, references: usable, question: question)
        VStack(alignment: .leading, spacing: 6) {
            SectionCaption("Candidate's answer")
            if text.isEmpty {
                Text(placeholder).foregroundStyle(.secondary)
            } else {
                HighlightedText(text: text, words: shared.answer)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let summary = shared.summary {
                Label {
                    Text(summary)
                } icon: {
                    RoundedRectangle(cornerRadius: 2).fill(HighlightedText.fill).frame(width: 14, height: 10)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("Runs of four or more words, in the same order, that also appear in one of the AI answers below.")
            }
        }
    }
}

/// A small all-caps section label that VoiceOver reads as a heading in
/// normal case.
struct SectionCaption: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Every question so far as a chip with its score, and the overall line.
/// Clicking a chip shows that question.
struct QuestionRail: View {
    let questions: [InterviewQuestionRecord]
    let scores: [String: AnswerScoreRecord]
    let activeID: String?
    let focusedID: String?
    let select: (String) -> Void

    private var finals: [AnswerScoreRecord] { questions.compactMap { scores[$0.id] }.filter(\.isFinal) }

    var body: some View {
        HStack(spacing: 14) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(questions) { question in chip(question).id(question.id) }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: questions.count) { _, _ in
                    guard let last = questions.last else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .trailing) }
                }
            }
            if let overall = InterviewSummary.overall(finals) {
                let flagged = finals.filter { $0.percent >= 70 }.count
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(overall)% overall")
                        .font(.callout.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(ScoreBand(percent: overall).color)
                    Text("\(flagged) of \(finals.count) flagged").font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize()
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func chip(_ question: InterviewQuestionRecord) -> some View {
        let score = scores[question.id]
        let isFocused = question.id == focusedID
        return Button { select(question.id) } label: {
            HStack(spacing: 6) {
                Text("Q\(question.ordinal)").fontWeight(.semibold)
                if question.id == activeID {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                    if let score {
                        Text("\(score.percent)%").monospacedDigit().foregroundStyle(.secondary)
                    }
                } else if let score {
                    Text("\(score.percent)%").monospacedDigit().fontWeight(.medium)
                        .foregroundStyle(ScoreBand(percent: score.percent).color)
                } else {
                    Text("\u{2013}").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(isFocused ? Color.accentColor.opacity(0.24) : Color.secondary.opacity(0.09)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(question.text.isEmpty ? "Q\(question.ordinal)" : question.text)
        .accessibilityLabel(chipLabel(question, score: score))
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }

    private func chipLabel(_ question: InterviewQuestionRecord, score: AnswerScoreRecord?) -> String {
        var parts = ["Question \(question.ordinal)"]
        if question.id == activeID { parts.append("being answered") }
        if let score { parts.append("\(score.percent) percent") }
        if !question.text.isEmpty { parts.append(question.text) }
        return parts.joined(separator: ", ")
    }
}

extension AnswerMetrics {
    /// Delivery traits that differ from person to person.
    var style: AnswerStyle {
        AnswerStyle(latency: substantiveLatency ?? firstWordLatency, wordCount: wordCount, hesitations: fillers + restarts)
    }
}

extension BaselineSignal {
    /// This answer against the same candidate's other finished answers.
    static func note(for questionID: String, scores: [String: AnswerScoreRecord]) -> String? {
        guard let score = scores[questionID], score.isFinal else { return nil }
        let others = scores.filter { $0.key != questionID && $0.value.isFinal }.map(\.value.metrics.style)
        return compare(score.metrics.style, with: others)
    }
}

