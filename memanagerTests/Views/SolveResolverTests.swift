import XCTest
@testable import memanager

final class SolveResolverTests: XCTestCase {

    // MARK: Complexity

    func testUnstatedNotationNeverShowsThePlaceholder() {
        let analysis = ComplexityAnalysis(notation: "O(?)", breakdown: "", type: .time)

        let presentation = ComplexityNotationPresenter.presentation(for: analysis)

        XCTAssertFalse(presentation.value.contains("?"))
        XCTAssertEqual(presentation.value, ComplexityNotationPresenter.unstatedValue)
        XCTAssertEqual(presentation.caption, ComplexityNotationPresenter.unstatedCaption)
        XCTAssertFalse(presentation.isStated)
    }

    func testUnstatedNotationKeepsTheBreakdownAfterTheNote() {
        let analysis = ComplexityAnalysis(notation: "O(?)", breakdown: "Linear in practice.", type: .space)

        let presentation = ComplexityNotationPresenter.presentation(for: analysis)

        XCTAssertEqual(presentation.caption, "Not stated. Linear in practice.")
        XCTAssertEqual(presentation.label, "Space")
    }

    func testStatedNotationPassesThrough() {
        let analysis = ComplexityAnalysis(notation: " O(n log n) ", breakdown: "Sort once.", type: .time)

        let presentation = ComplexityNotationPresenter.presentation(for: analysis)

        XCTAssertEqual(presentation.value, "O(n log n)")
        XCTAssertEqual(presentation.caption, "Sort once.")
        XCTAssertTrue(presentation.isStated)
    }

    // MARK: Questions

    func testQuestionNumberingRunsAcrossGroupsAndSkipsEmptyOnes() {
        let content = QuestionsContent(
            edgeCaseQuestions: [
                Question(text: "Empty input?", assumption: "Return zero", category: .edgeCase),
                Question(text: "Case sensitive?", assumption: nil, category: .edgeCase)
            ],
            constraintQuestions: [],
            validationQuestions: [Question(text: "Nil input?", assumption: nil, category: .validation)],
            rawContent: ""
        )

        let groups = QuestionGroupResolver.groups(from: content)

        XCTAssertEqual(groups.map(\.id), [.edgeCase, .validation])
        XCTAssertEqual(groups.map(\.firstNumber), [1, 3])
        XCTAssertEqual(groups.first?.title, "Edge cases to clarify")
    }

    // MARK: Tests

    func testTestGroupsKeepWalkthroughOrderAndTones() {
        let content = TestsContent(
            baseCases: [TestCase(input: "abc", expected: "3", reasoning: nil, category: .base)],
            edgeCases: [TestCase(input: "", expected: "0", reasoning: "empty", category: .edge)],
            errorCases: [TestCase(input: "None", expected: "0", reasoning: nil, category: .error)],
            rawContent: ""
        )

        let groups = TestGroupResolver.groups(from: content)

        XCTAssertEqual(groups.map(\.id), [.base, .edge, .error])
        XCTAssertEqual(groups.map(\.tone), [.success, .warning, .critical])
    }

    func testExpectedValueChipLimit() {
        XCTAssertTrue(TestExpectationPresenter.fitsChip("3"))
        XCTAssertTrue(TestExpectationPresenter.fitsChip("[1, 2, 3, 4, 5]"))
        XCTAssertFalse(TestExpectationPresenter.fitsChip(""))
        XCTAssertFalse(TestExpectationPresenter.fitsChip("a\nb"))
        XCTAssertFalse(TestExpectationPresenter.fitsChip(String(repeating: "x", count: 40)))
    }

    // MARK: Tone policy

    func testEachConstraintKindHasItsOwnTone() {
        let tones = Constraint.ConstraintType.allCases.map { SolveTonePolicy.tone(for: $0) }

        XCTAssertEqual(Set(tones).count, tones.count)
        XCTAssertFalse(tones.contains(.critical), "a constraint is never an error")
    }

    // MARK: Implementation captions

    func testStepCaptionClampsIntoRange() {
        XCTAssertEqual(ImplementationStepPresenter.caption(current: 2, total: 6), "Step 2 of 6")
        XCTAssertEqual(ImplementationStepPresenter.caption(current: 9, total: 6), "Step 6 of 6")
        XCTAssertEqual(ImplementationStepPresenter.caption(current: 0, total: 6), "Step 1 of 6")
        XCTAssertEqual(ImplementationStepPresenter.caption(current: 1, total: 0), "No steps yet")
    }

    func testTeleprompterCaptionIsOneBased() {
        XCTAssertEqual(ImplementationStepPresenter.teleprompterCaption(TeleprompterProgress(current: 0, total: 5)), "1 of 5")
        XCTAssertEqual(ImplementationStepPresenter.teleprompterCaption(TeleprompterProgress(current: 0, total: 0)), "Ready")
    }

    // MARK: Spoken lines

    private func makeStep(range: ClosedRange<Int>?, snippet: String = "") -> ImplementationStep {
        ImplementationStep(
            number: 1,
            title: "Set up",
            reasoning: "First chunk.\n\nSecond chunk.",
            codeSnippet: snippet,
            cumulativeCode: "def f(s):\n    left = 0\n    best = 0",
            language: "python",
            addedLineRange: range
        )
    }

    func testSpokenLinesUseTheAddedRangeWithLineNumbers() {
        let lines = SpokenLineResolver.lines(for: makeStep(range: 2...3), style: .mixed)

        XCTAssertEqual(lines.map(\.lineNumber), [2, 3])
        XCTAssertEqual(lines.map(\.id), [0, 1])
        XCTAssertEqual(lines.first?.gutter, "L2")
    }

    func testSpokenLinesFallBackToTheSnippetWithoutNumbers() {
        let lines = SpokenLineResolver.lines(for: makeStep(range: nil, snippet: "best = 0"), style: .literal)

        XCTAssertEqual(lines.count, 1)
        XCTAssertNil(lines.first?.lineNumber)
        XCTAssertEqual(lines.first?.gutter, "")
    }

    func testSpokenLinesFallBackToTheWholeListing() {
        let lines = SpokenLineResolver.lines(for: makeStep(range: nil), style: .mixed)

        XCTAssertEqual(lines.count, 3)
    }

    // MARK: Chunks

    func testChunkSplitterCountsBlankLineParagraphs() {
        let chunks = SpeakableChunkSplitter.chunks(from: "one\n\n\n two \n\nthree")

        XCTAssertEqual(chunks.map(\.content), ["one", "two", "three"])
        XCTAssertEqual(chunks.map(\.number), [1, 2, 3])
    }

    func testChunkPreviewTakesTheFirstLineAndTruncates() {
        XCTAssertEqual(SpeakableChunkSplitter.preview(of: "short line\nsecond\n\nnext"), "short line")
        XCTAssertNil(SpeakableChunkSplitter.preview(of: "   \n\n  "))
        let long = String(repeating: "a", count: 120)
        XCTAssertEqual(SpeakableChunkSplitter.preview(of: long, limit: 10), "aaaaaaaaaa" + SpeakableChunkSplitter.ellipsis)
    }

    func testChunkReadingStateFollowsTheCursor() {
        XCTAssertEqual(SpeakableChunkReadingState.resolve(index: 1, teleprompterEnabled: false, currentIndex: 1), .plain)
        XCTAssertEqual(SpeakableChunkReadingState.resolve(index: 1, teleprompterEnabled: true, currentIndex: 1), .current)
        XCTAssertEqual(SpeakableChunkReadingState.resolve(index: 0, teleprompterEnabled: true, currentIndex: 1), .past)
        XCTAssertEqual(SpeakableChunkReadingState.resolve(index: 2, teleprompterEnabled: true, currentIndex: 1), .upcoming)
    }
}
