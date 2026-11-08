import Foundation

struct QuickAssistToolBackedAnswerReview: Equatable {
    let needsRevision: Bool
    let shouldMarkNeedsReview: Bool
    let reason: String?
}

final class QuickAssistToolBackedAnswerReviewer {
    func review(responseText: String, trace: QuickAssistToolTrace) -> QuickAssistToolBackedAnswerReview {
        let evidenceHeavySteps = trace.steps.filter {
            switch $0.evidenceKind {
            case .read, .search:
                return $0.state == .completed
            case .directory, .generic:
                return false
            }
        }
        guard !evidenceHeavySteps.isEmpty else {
            return QuickAssistToolBackedAnswerReview(
                needsRevision: false,
                shouldMarkNeedsReview: false,
                reason: nil
            )
        }

        let normalized = responseText.lowercased()
        let hasCodeBlock = responseText.contains("```")
        let references = trace.referencedFiles
        let hasFileCitation = references.contains { reference in
            responseText.contains(reference.path) ||
            responseText.contains((reference.path as NSString).lastPathComponent)
        }
        let hasLineReference = references.contains { reference in
            reference.lines.contains { line in
                responseText.contains(":\(line)") ||
                normalized.contains("line \(line)")
            }
        }
        let proposesChange = [
            "add ", "replace ", "update ", "change ", "modify ",
            "remove ", "refactor ", "fix ", "patch "
        ].contains { normalized.contains($0) }

        let missingCitations = !hasFileCitation || !hasLineReference
        let missingCodeBlock = !hasCodeBlock
        let needsRevision = missingCitations || missingCodeBlock
        guard needsRevision else {
            return QuickAssistToolBackedAnswerReview(
                needsRevision: false,
                shouldMarkNeedsReview: false,
                reason: nil
            )
        }

        let reason: String
        if missingCitations && (proposesChange || missingCodeBlock) {
            reason = "Tool backed answer is missing exact file citations, line references, or fenced code evidence."
        } else if missingCitations {
            reason = "Tool backed answer is missing exact file citations or line references."
        } else {
            reason = proposesChange
                ? "Tool backed change proposal is missing a fenced code block or diff."
                : "Tool backed answer is missing a fenced code excerpt."
        }

        return QuickAssistToolBackedAnswerReview(
            needsRevision: true,
            shouldMarkNeedsReview: true,
            reason: reason
        )
    }
}
