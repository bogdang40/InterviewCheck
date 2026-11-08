import Foundation

struct MentorResponse: Codable {
    var problem: String
    var clarifyingQuestions: String
    var implementation: String      // Unified approach + code section
    var tests: String
    var complexity: String
    var systemDesign: String        // System design section for design questions

    // Backward compatibility - code returns final code from implementation
    var code: String {
        parsedImplementation.finalCode
    }

    static let empty = MentorResponse(
        problem: "",
        clarifyingQuestions: "",
        implementation: "",
        tests: "",
        complexity: "",
        systemDesign: ""
    )

    enum Section: Int, CaseIterable, Identifiable {
        case problem = 0
        case clarifyingQuestions
        case implementation     // Renamed from approach, replaces code
        case tests
        case complexity
        case systemDesign       // System design section (Cmd+6)

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .problem: return "Problem"
            case .clarifyingQuestions: return "Clarify"
            case .implementation: return "Implementation"
            case .tests: return "Tests"
            case .complexity: return "Complexity"
            case .systemDesign: return "Design"
            }
        }

        var icon: String {
            switch self {
            case .problem: return "doc.text"
            case .clarifyingQuestions: return "questionmark.circle"
            case .implementation: return "hammer"
            case .tests: return "checkmark.shield"
            case .complexity: return "chart.bar"
            case .systemDesign: return "building.2"
            }
        }

        var shortcut: String {
            return "Cmd+\(rawValue + 1)"
        }
    }

    func content(for section: Section) -> String {
        switch section {
        case .problem: return problem
        case .clarifyingQuestions: return clarifyingQuestions
        case .implementation: return implementation
        case .tests: return tests
        case .complexity: return complexity
        case .systemDesign: return systemDesign
        }
    }

    static func parse(from text: String) -> MentorResponse {
        var response = MentorResponse.empty
        let lines = text.components(separatedBy: "\n")

        var sections: [Section: [String]] = [:]
        var currentSection: Section?

        for line in lines {
            if let section = parseSectionHeader(from: line) {
                currentSection = section
                continue
            }

            if let section = currentSection {
                sections[section, default: []].append(line)
            }
        }

        for (section, contentLines) in sections {
            let content = contentLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch section {
            case .problem:
                response.problem = content
            case .clarifyingQuestions:
                response.clarifyingQuestions = content
            case .implementation:
                response.implementation = content
            case .tests:
                response.tests = content
            case .complexity:
                response.complexity = content
            case .systemDesign:
                response.systemDesign = content
            }
        }

        return response
    }

    private static func parseSectionHeader(from line: String) -> Section? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("#") {
            let title = normalizeHeader(String(trimmed.drop(while: { $0 == "#" })))
            return sectionLookup[title]
        }

        if trimmed.hasPrefix("**"), let boldTitle = extractBoldHeader(from: trimmed) {
            let normalized = normalizeHeader(boldTitle)
            return sectionLookup[normalized]
        }

        let normalized = normalizeHeader(trimmed)
        return sectionLookup[normalized]
    }

    private static func extractBoldHeader(from line: String) -> String? {
        let pattern = #"^\*\*([^*]+?)\*\*\s*:?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let nsString = line as NSString
        let range = NSRange(location: 0, length: nsString.length)
        guard let match = regex.firstMatch(in: line, range: range),
              match.range(at: 1).location != NSNotFound else { return nil }

        return nsString.substring(with: match.range(at: 1))
    }

    private static func normalizeHeader(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .lowercased()
    }

    private static let sectionLookup: [String: Section] = [
        "problem": .problem,
        "clarifying questions": .clarifyingQuestions,
        "clarifying question": .clarifyingQuestions,
        "clarify": .clarifyingQuestions,
        "questions": .clarifyingQuestions,
        "implementation": .implementation,
        "approach": .implementation,
        "solution": .implementation,
        "tests": .tests,
        "test cases": .tests,
        "complexity": .complexity,
        "big o": .complexity,
        "system design": .systemDesign,
        "design": .systemDesign
    ]
}
