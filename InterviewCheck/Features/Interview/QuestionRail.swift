import SwiftUI
import InterviewCheckKit

/// Every question so far as a chip with its score, and the overall line.
/// Clicking a chip shows that question.
struct QuestionRail: View {
    let questions: [InterviewQuestionRecord]
    let scores: [String: AnswerScoreRecord]
    let activeID: String?
    let focusedID: String?
    /// Off where the screen already says how many answers were flagged.
    var showsSummary = true
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
            if showsSummary, let overall = InterviewSummary.overall(finals) {
                let flagged = finals.filter { $0.percent >= 70 }.count
                VStack(alignment: .trailing, spacing: 1) {
                    Text(InterviewSummary.flaggedLine(flagged, of: finals.count))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(flagged > 0 ? ScoreBand.flagged.color : .primary)
                    Text("\(overall)% overall").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                .fixedSize()
                .accessibilityElement(children: .combine)
                .help(InterviewSummary.overallHelp)
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
                    Circle().fill(Palette.live).frame(width: 6, height: 6)
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
            .background(Capsule().fill(isFocused ? Color.primary.opacity(0.16) : Color.secondary.opacity(0.08)))
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
