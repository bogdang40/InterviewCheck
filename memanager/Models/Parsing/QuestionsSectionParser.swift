import Foundation

/// Parses the Clarifying Questions section of a mentor response.
enum QuestionsSectionParser {
    // MARK: - Questions Section Parser

    static func parseQuestions(_ text: String) -> QuestionsContent {
        let edgeCaseRaw = MarkdownSectionGrammar.extractContent(after: "Edge cases to clarify", in: text)
        let constraintRaw = MarkdownSectionGrammar.extractContent(after: "Constraints to confirm", in: text)
        let validationRaw = MarkdownSectionGrammar.extractContent(after: "Input validation", in: text)

        return QuestionsContent(
            edgeCaseQuestions: parseQuestionList(edgeCaseRaw, category: .edgeCase),
            constraintQuestions: parseQuestionList(constraintRaw, category: .constraint),
            validationQuestions: parseQuestionList(validationRaw, category: .validation),
            rawContent: text
        )
    }

    private static func parseQuestionList(_ text: String?, category: Question.QuestionCategory) -> [Question] {
        guard let text = text else { return [] }

        var questions: [Question] = []
        let lines = text.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Remove bullet points
            var content = trimmed
            if content.hasPrefix("-") || content.hasPrefix("*") || content.hasPrefix("\"") {
                content = String(content.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if content.hasSuffix("\"") {
                content = String(content.dropLast())
            }

            // Extract assumption if present: (Assuming: ...)
            var assumption: String?
            let assumptionPattern = #"\(Assuming:\s*([^)]+)\)"#
            if let regex = try? NSRegularExpression(pattern: assumptionPattern),
               let match = regex.firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length)),
               match.range(at: 1).location != NSNotFound {
                assumption = (content as NSString).substring(with: match.range(at: 1))
                content = regex.stringByReplacingMatches(in: content, range: NSRange(location: 0, length: (content as NSString).length), withTemplate: "")
                    .trimmingCharacters(in: .whitespaces)
            }

            if !content.isEmpty {
                questions.append(Question(text: content, assumption: assumption, category: category))
            }
        }

        return questions
    }
}
