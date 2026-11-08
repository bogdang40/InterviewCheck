import Foundation

/// Parses the `COMPLETION_CHECKLIST: Requirements=2, ...` line the system
/// design prompt demands as its final line. The line was demanded by both
/// the prompt and every recovery request but parsed nowhere; it now feeds an
/// advisory cross check against the actually parsed step counts.
enum SystemDesignChecklistParser {
    static let marker = "COMPLETION_CHECKLIST:"

    /// The prompt's standalone protocol lines are not spoken design content.
    /// Keep inline mentions and code examples, and retain partially streamed
    /// checklist lines as metadata even before their counts are complete.
    static func removingMetadataLines(from text: String) -> String {
        guard text.contains(marker) else { return text }
        var fence: (character: Character, count: Int)?
        return text.components(separatedBy: "\n").filter { line in
            let indentation = line.prefix { $0 == " " }.count
            guard indentation < 4, !line.hasPrefix("\t") else { return true }
            let candidate = line.trimmingCharacters(in: .whitespaces)
            if let active = fence {
                let closing = candidate.prefix { $0 == active.character }
                if closing.count >= active.count,
                   candidate.dropFirst(closing.count).trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                }
                return true
            }
            if let character = candidate.first, character == "`" || character == "~" {
                let count = candidate.prefix { $0 == character }.count
                if count >= 3 { fence = (character, count) }
                return true
            }
            return !candidate.hasPrefix(marker)
        }.joined(separator: "\n")
    }

    /// Section title (as written by the model) to declared step count.
    static func parse(_ text: String) -> [String: Int] {
        guard let markerRange = text.range(of: marker, options: .backwards) else {
            return [:]
        }
        let lineTail = text[markerRange.upperBound...]
        let line = lineTail.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""

        var declared: [String: Int] = [:]
        for entry in line.split(separator: ",") {
            let parts = entry.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  let count = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
                continue
            }
            let title = parts[0].trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            declared[title] = count
        }
        return declared
    }

    /// Sections whose declared count disagrees with what actually parsed.
    static func mismatches(
        declared: [String: Int],
        actualBySectionTitle: [String: Int]
    ) -> [String] {
        declared.compactMap { title, declaredCount in
            guard let actual = actualBySectionTitle[title], actual != declaredCount else {
                return actualBySectionTitle[title] == nil ? "\(title): declared \(declaredCount), parsed none" : nil
            }
            return "\(title): declared \(declaredCount), parsed \(actual)"
        }.sorted()
    }
}
