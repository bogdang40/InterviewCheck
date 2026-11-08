import SwiftUI
import InterviewCheckKit

/// One AI answer, streaming in, with the words the candidate also said
/// highlighted.
struct ReferenceCard: View {
    let answer: ReferenceAnswerRecord
    var isBestMatch = false
    var shared: SharedWords = .none
    /// False while there is no candidate answer to compare with.
    var compares = false
    @State private var showsAll = false

    /// Long answers show their first lines until "Show All".
    private var isLong: Bool { answer.text.split(whereSeparator: \.isWhitespace).count > 70 }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Tag(text: answer.promptName)
                    if shared.sharedCount > 0 {
                        MarkerTag(text: "\(shared.sharedCount) words match")
                            .help("The candidate said these \(shared.sharedCount) words in the same order (highlighted).")
                    } else if compares, !answer.isStreaming, answer.error == nil, !answer.text.isEmpty {
                        Tag(text: "No overlap")
                            .help("No run of four or more words in the candidate's answer matches this one.")
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
                Group {
                    if answer.text.isEmpty {
                        Text(answer.error == nil ? "Writing\u{2026}" : "No answer").foregroundStyle(.secondary)
                    } else {
                        HighlightedText(text: answer.text, words: shared.reference)
                            .lineLimit(showsAll || !isLong ? nil : 9)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                if isLong {
                    Button(showsAll ? "Show Less" : "Show All") { withAnimation(.easeOut(duration: 0.15)) { showsAll.toggle() } }
                        .buttonStyle(.link)
                        .font(.callout)
                }
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
                if isBestMatch { Tag(text: "Closest match") }
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
                                  : SharedWords.find(answer: candidateAnswer, reference: answer.text, question: question),
                              compares: !candidateAnswer.isEmpty)
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

    static let fill = Palette.marker

    static func attributed(_ text: String, words: Set<Int>) -> AttributedString {
        var result = AttributedString(text)
        for range in SharedWords.highlightRanges(text, words: words) {
            guard let target = Range(range, in: result) else { continue }
            result[target].backgroundColor = fill
            result[target].foregroundColor = .black
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
