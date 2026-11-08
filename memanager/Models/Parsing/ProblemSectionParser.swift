import Foundation

/// Parses the Problem section of a mentor response.
enum ProblemSectionParser {
    // MARK: - Problem Section Parser

    static func parseProblem(_ text: String) -> ProblemContent {
        let restatement = MarkdownSectionGrammar.extractContent(after: "Restating the problem", in: text)
        let constraintsRaw = MarkdownSectionGrammar.extractContent(after: "Key constraints", in: text)
        let insight = MarkdownSectionGrammar.extractContent(after: "The real insight here", in: text)
        let correctnessProof = MarkdownSectionGrammar.extractContent(after: "Why this approach is correct", in: text)

        var constraints: [Constraint] = []
        if let constraintsRaw = constraintsRaw {
            constraints = parseConstraints(from: constraintsRaw)
        }

        return ProblemContent(
            restatement: restatement,
            constraints: constraints,
            insight: insight,
            correctnessProof: correctnessProof,
            rawContent: text
        )
    }

    private static func parseConstraints(from text: String) -> [Constraint] {
        var constraints: [Constraint] = []

        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("-") || trimmed.hasPrefix("*") else { continue }

            let content = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)

            for type in Constraint.ConstraintType.allCases {
                let prefix = "\(type.rawValue):"
                if content.hasPrefix(prefix) {
                    let description = String(content.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    constraints.append(Constraint(type: type, description: description))
                    break
                }
            }
        }

        return constraints
    }
}
