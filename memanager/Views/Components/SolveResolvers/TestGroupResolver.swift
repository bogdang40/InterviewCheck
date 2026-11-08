import Foundation

/// One group of test cases with the tone every expected value in it wears.
struct TestGroup: Identifiable {
    let id: TestCase.TestCategory
    let title: String
    let tone: OverlayTone
    let cases: [TestCase]
}

/// Orders the test groups the way a walkthrough goes: the happy path
/// first, then the edges, then the inputs that should fail.
enum TestGroupResolver {
    static func groups(from content: TestsContent) -> [TestGroup] {
        let ordered: [(TestCase.TestCategory, String, [TestCase])] = [
            (.base, "Base cases", content.baseCases),
            (.edge, "Edge cases", content.edgeCases),
            (.error, "Error cases", content.errorCases)
        ]
        return ordered.compactMap { category, title, cases in
            guard !cases.isEmpty else { return nil }
            return TestGroup(id: category, title: title, tone: SolveTonePolicy.tone(for: category), cases: cases)
        }
    }
}

/// Decides whether an expected value is short enough for a chip or needs
/// a wrapping line of monospaced text.
enum TestExpectationPresenter {
    static let chipCharacterLimit = 32

    static func fitsChip(_ expected: String) -> Bool {
        let trimmed = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return false }
        return trimmed.count <= chipCharacterLimit
    }
}
