import Foundation

enum BehaviouralResponseStyle: String, Equatable {
    case starPlus = "star_plus"
    case conversationalException = "conversational_exception"

    var routeLabel: String {
        switch self {
        case .starPlus:
            return "STAR+"
        case .conversationalException:
            return "Conversational"
        }
    }
}

enum BehaviouralExceptionReason: String, Equatable {
    case autoSideQuestion = "auto_side_question"
    case probeQuestion = "probe_question"
    case simpleIntroQuestion = "simple_intro_question"
}

struct BehaviouralResponseStyleDecision: Equatable {
    let style: BehaviouralResponseStyle
    let exceptionReason: BehaviouralExceptionReason?

    static let starPlus = BehaviouralResponseStyleDecision(
        style: .starPlus,
        exceptionReason: nil
    )

    static func conversational(_ reason: BehaviouralExceptionReason) -> BehaviouralResponseStyleDecision {
        BehaviouralResponseStyleDecision(
            style: .conversationalException,
            exceptionReason: reason
        )
    }
}

final class BehaviouralResponseStyleResolver {
    private let probeTerms = [
        "follow up",
        "can you elaborate",
        "elaborate on",
        "dig deeper",
        "drill down",
        "tell me more",
        "what was your role",
        "how did you handle",
        "why did you choose",
        "what was the outcome"
    ]

    private let simpleIntroTerms = [
        "tell me about yourself",
        "walk me through your resume",
        "introduce yourself",
        "why this role",
        "why this company",
        "what are your strengths",
        "what is your biggest strength",
        "what are your weaknesses",
        "what is your biggest weakness"
    ]

    func resolve(
        question: String,
        transcript: String,
        questionSource: QuickAssistQuestionSource
    ) -> BehaviouralResponseStyleDecision {
        if questionSource == .auto {
            return .conversational(.autoSideQuestion)
        }

        let primary = primaryText(question: question, transcript: transcript)
        guard !primary.isEmpty else {
            return .starPlus
        }

        if containsAnyTerm(in: primary, terms: probeTerms) {
            return .conversational(.probeQuestion)
        }

        if containsAnyTerm(in: primary, terms: simpleIntroTerms) {
            return .conversational(.simpleIntroQuestion)
        }

        return .starPlus
    }

    private func primaryText(question: String, transcript: String) -> String {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuestion.isEmpty {
            return normalize(trimmedQuestion)
        }

        let lastTranscriptLine = latestTranscriptLine(transcript)
        return normalize(lastTranscriptLine)
    }

    private func latestTranscriptLine(_ transcript: String) -> String {
        for line in transcript.components(separatedBy: .newlines).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            return stripSpeakerPrefix(from: trimmed)
        }
        return ""
    }

    private func stripSpeakerPrefix(from line: String) -> String {
        let speakerPattern = #"^(?i)(me|speaker\s+\d+)\s*:\s*"#
        guard let range = line.range(of: speakerPattern, options: .regularExpression) else {
            return line
        }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalize(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsAnyTerm(in source: String, terms: [String]) -> Bool {
        terms.contains { term in
            hasTerm(term, in: source)
        }
    }

    private func hasTerm(_ term: String, in source: String) -> Bool {
        let normalizedTerm = normalize(term)
        guard !normalizedTerm.isEmpty else { return false }

        var escaped = NSRegularExpression.escapedPattern(for: normalizedTerm)
        escaped = escaped.replacingOccurrences(of: #"\ "#, with: #"\s+"#)
        let pattern = "(^|[^a-z0-9])\(escaped)([^a-z0-9]|$)"
        return source.range(of: pattern, options: .regularExpression) != nil
    }
}
