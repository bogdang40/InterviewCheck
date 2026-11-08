import Foundation

/// Extracts the identifiers a mermaid diagram talks about so two steps can
/// be compared: what the current step kept from the previous one and what it
/// introduced. Shared by the stepper's context rows and the script narration.
enum DesignDiagramTokenizer {
    struct Delta: Equatable {
        let kept: [String]
        let added: [String]

        var isEmpty: Bool { kept.isEmpty && added.isEmpty }
    }

    private static let stopWords: Set<String> = [
        "flowchart", "graph", "sequencediagram", "erdiagram",
        "classdiagram", "statediagram", "left", "right"
    ]

    static func tokens(in mermaid: String) -> Set<String> {
        let parts = mermaid.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return Set(
            parts
                .map(String.init)
                .map { $0.trimmingCharacters(in: CharacterSet.decimalDigits) }
                .filter { $0.count >= 3 && !stopWords.contains($0) }
        )
    }

    /// Up to `limit` kept and added identifiers, sorted for stable wording.
    static func delta(from previous: String, to current: String, limit: Int = 3) -> Delta {
        let before = tokens(in: previous)
        let after = tokens(in: current)
        return Delta(
            kept: Array(after.intersection(before).sorted().prefix(limit)),
            added: Array(after.subtracting(before).sorted().prefix(limit))
        )
    }
}
