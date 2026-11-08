import Foundation

/// Parses the Tests section of a mentor response.
enum TestsSectionParser {
    // MARK: - Tests Section Parser

    static func parseTests(_ text: String) -> TestsContent {
        let baseRaw = MarkdownSectionGrammar.extractContent(after: "Base cases", in: text)
        let edgeRaw = MarkdownSectionGrammar.extractContent(after: "Edge cases", in: text)
        let errorRaw = MarkdownSectionGrammar.extractContent(after: "Error cases", in: text)

        return TestsContent(
            baseCases: parseTestCases(baseRaw, category: .base),
            edgeCases: parseTestCases(edgeRaw, category: .edge),
            errorCases: parseTestCases(errorRaw, category: .error),
            rawContent: text
        )
    }

    private static func parseTestCases(_ text: String?, category: TestCase.TestCategory) -> [TestCase] {
        guard let text = text else { return [] }

        var cases: [TestCase] = []

        // Match: `input` -> `expected` (reasoning)
        let pattern = #"`([^`]+)`\s*->\s*`([^`]+)`(?:\s*\(([^)]+)\))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return cases }

        let nsString = text as NSString
        let range = NSRange(location: 0, length: nsString.length)

        for match in regex.matches(in: text, range: range) {
            guard match.range(at: 1).location != NSNotFound,
                  match.range(at: 2).location != NSNotFound else { continue }

            let input = nsString.substring(with: match.range(at: 1))
            let expected = nsString.substring(with: match.range(at: 2))

            var reasoning: String?
            if match.range(at: 3).location != NSNotFound {
                reasoning = nsString.substring(with: match.range(at: 3))
            }

            cases.append(TestCase(input: input, expected: expected, reasoning: reasoning, category: category))
        }

        return cases
    }
}
