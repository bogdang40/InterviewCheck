import XCTest
@testable import memanager

/// Characterization ("golden") tests that freeze the CURRENT behavior of
/// SectionParser before refactoring. If one of these fails after a refactor,
/// the refactor changed observable behavior. Expectations here mirror what
/// the current code produces, quirks included; never "fix" production code
/// to satisfy these tests.
final class SectionParserGoldenTests: XCTestCase {

    // MARK: - parseProblem

    func testParseProblemFullFeaturedInput() {
        let fixture = """
        ## Problem

        **Restating the problem:**
        We need the longest contiguous window of unique characters.
        This is a classic sliding window problem.

        **Key constraints:**
        - Time: O(n) expected because n can reach 100000
        - Space: O(k) auxiliary storage is acceptable
        - Input: ASCII string, possibly empty
        - Output: Return the window length as an integer

        **The real insight here:**
        Window validity is monotonic, so the left edge never moves backwards.

        **Why this approach is correct:**
        The uniqueness invariant holds after every pointer move.
        """

        let content = SectionParser.parseProblem(fixture)

        XCTAssertEqual(
            content.restatement,
            "We need the longest contiguous window of unique characters.\nThis is a classic sliding window problem."
        )
        XCTAssertEqual(content.constraints.count, 4)
        XCTAssertEqual(content.constraints[0].type, .time)
        XCTAssertEqual(content.constraints[0].description, "O(n) expected because n can reach 100000")
        XCTAssertEqual(content.constraints[1].type, .space)
        XCTAssertEqual(content.constraints[1].description, "O(k) auxiliary storage is acceptable")
        XCTAssertEqual(content.constraints[2].type, .input)
        XCTAssertEqual(content.constraints[2].description, "ASCII string, possibly empty")
        XCTAssertEqual(content.constraints[3].type, .output)
        XCTAssertEqual(content.constraints[3].description, "Return the window length as an integer")
        XCTAssertEqual(
            content.insight,
            "Window validity is monotonic, so the left edge never moves backwards."
        )
        XCTAssertEqual(
            content.correctnessProof,
            "The uniqueness invariant holds after every pointer move."
        )
        XCTAssertEqual(content.rawContent, fixture)
        XCTAssertTrue(content.hasStructuredContent)
    }

    func testParseProblemHeaderlessInputYieldsEmptyStructure() {
        let fixture = "Just some prose without any recognized section headers."

        let content = SectionParser.parseProblem(fixture)

        XCTAssertNil(content.restatement)
        XCTAssertTrue(content.constraints.isEmpty)
        XCTAssertNil(content.insight)
        XCTAssertNil(content.correctnessProof)
        XCTAssertEqual(content.rawContent, fixture)
        XCTAssertTrue(content.isEmpty)
    }

    // MARK: - parseQuestions

    func testParseQuestionsFullFeaturedInput() {
        let fixture = """
        ## Clarifying Questions

        **Edge cases to clarify:**
        "What happens if the string is empty?" (Assuming: return 0)
        "What about a single repeated character?" (Assuming: answer is 1)

        **Constraints to confirm:**
        "Can we assume ASCII input only?" (Assuming: yes, 128 characters)

        **Input validation:**
        "Do we need to handle nil input?" (Assuming: caller guarantees non-nil)
        """

        let content = SectionParser.parseQuestions(fixture)

        // Current behavior: only ONE leading bullet or quote character is
        // stripped, and the trailing quote survives because the suffix check
        // runs before the assumption text is removed.
        XCTAssertEqual(content.edgeCaseQuestions.count, 2)
        XCTAssertEqual(content.edgeCaseQuestions[0].text, "What happens if the string is empty?\"")
        XCTAssertEqual(content.edgeCaseQuestions[0].assumption, "return 0")
        XCTAssertEqual(content.edgeCaseQuestions[0].category, .edgeCase)
        XCTAssertEqual(content.edgeCaseQuestions[1].text, "What about a single repeated character?\"")
        XCTAssertEqual(content.edgeCaseQuestions[1].assumption, "answer is 1")

        XCTAssertEqual(content.constraintQuestions.count, 1)
        XCTAssertEqual(content.constraintQuestions[0].text, "Can we assume ASCII input only?\"")
        XCTAssertEqual(content.constraintQuestions[0].assumption, "yes, 128 characters")
        XCTAssertEqual(content.constraintQuestions[0].category, .constraint)

        XCTAssertEqual(content.validationQuestions.count, 1)
        XCTAssertEqual(content.validationQuestions[0].text, "Do we need to handle nil input?\"")
        XCTAssertEqual(content.validationQuestions[0].assumption, "caller guarantees non-nil")
        XCTAssertEqual(content.validationQuestions[0].category, .validation)

        XCTAssertEqual(content.rawContent, fixture)
    }

    func testParseQuestionsEmptyInputYieldsEmptyStructure() {
        let content = SectionParser.parseQuestions("")

        XCTAssertTrue(content.edgeCaseQuestions.isEmpty)
        XCTAssertTrue(content.constraintQuestions.isEmpty)
        XCTAssertTrue(content.validationQuestions.isEmpty)
        XCTAssertEqual(content.rawContent, "")
        XCTAssertTrue(content.isEmpty)
    }

    // MARK: - parseImplementation

    func testParseImplementationTwoStepCumulativeInput() {
        let fixture = """
        **Step 1: Set up tracking**

        I want a dictionary mapping each character to its most recent index.
        That gives constant time duplicate checks.

        ```python
        # NEW: lines 1-3
        def longest_unique(s):
            seen = {}
            left = 0
        ```

        **Step 2: Slide the window**

        Now I expand right and jump left past duplicates.

        ```python
        # NEW: lines 4-6
        def longest_unique(s):
            seen = {}
            left = 0
            best = 0
            for right, ch in enumerate(s):
                best = max(best, right - left + 1)
        ```
        """

        let step1Code = """
        def longest_unique(s):
            seen = {}
            left = 0
        """

        let step2Code = """
        def longest_unique(s):
            seen = {}
            left = 0
            best = 0
            for right, ch in enumerate(s):
                best = max(best, right - left + 1)
        """

        let step2Snippet = """
            best = 0
            for right, ch in enumerate(s):
                best = max(best, right - left + 1)
        """

        let content = SectionParser.parseImplementation(fixture)

        XCTAssertEqual(content.language, "python")
        XCTAssertEqual(content.steps.count, 2)

        let first = content.steps[0]
        XCTAssertEqual(first.number, 1)
        XCTAssertEqual(first.title, "Set up tracking")
        XCTAssertEqual(
            first.reasoning,
            "I want a dictionary mapping each character to its most recent index.\nThat gives constant time duplicate checks."
        )
        XCTAssertEqual(first.codeSnippet, step1Code)
        XCTAssertEqual(first.cumulativeCode, step1Code)
        XCTAssertEqual(first.language, "python")
        XCTAssertEqual(first.addedLineRange, 1...3)

        let second = content.steps[1]
        XCTAssertEqual(second.number, 2)
        XCTAssertEqual(second.title, "Slide the window")
        XCTAssertEqual(second.reasoning, "Now I expand right and jump left past duplicates.")
        XCTAssertEqual(second.codeSnippet, step2Snippet)
        XCTAssertEqual(second.cumulativeCode, step2Code)
        XCTAssertEqual(second.language, "python")
        XCTAssertEqual(second.addedLineRange, 4...6)

        XCTAssertEqual(content.finalCode, step2Code)
        XCTAssertEqual(content.rawContent, fixture)
    }

    func testParseImplementationHeaderlessProseFallsBackToRawOnly() {
        let fixture = "This is plain discussion without step headers or code fences."

        let content = SectionParser.parseImplementation(fixture)

        XCTAssertTrue(content.steps.isEmpty)
        XCTAssertEqual(content.language, "python")
        XCTAssertEqual(content.rawContent, fixture)
        XCTAssertEqual(content.finalCode, "")
        XCTAssertFalse(content.hasStructuredSteps)
        XCTAssertTrue(content.hasContent)
    }

    // MARK: - parseTests

    func testParseTestsFullFeaturedInput() {
        let fixture = """
        ## Tests

        **Base cases:**
        `"abcabcbb"` -> `3` (classic repeating pattern)
        `"pwwkew"` -> `3` (window must be contiguous)

        **Edge cases:**
        `""` -> `0` (empty string has answer zero)

        **Error cases:**
        `nil` -> `ValueError` (reject missing input)
        """

        let content = SectionParser.parseTests(fixture)

        XCTAssertEqual(content.baseCases.count, 2)
        XCTAssertEqual(content.baseCases[0].input, "\"abcabcbb\"")
        XCTAssertEqual(content.baseCases[0].expected, "3")
        XCTAssertEqual(content.baseCases[0].reasoning, "classic repeating pattern")
        XCTAssertEqual(content.baseCases[0].category, .base)
        XCTAssertEqual(content.baseCases[1].input, "\"pwwkew\"")
        XCTAssertEqual(content.baseCases[1].expected, "3")
        XCTAssertEqual(content.baseCases[1].reasoning, "window must be contiguous")

        XCTAssertEqual(content.edgeCases.count, 1)
        XCTAssertEqual(content.edgeCases[0].input, "\"\"")
        XCTAssertEqual(content.edgeCases[0].expected, "0")
        XCTAssertEqual(content.edgeCases[0].reasoning, "empty string has answer zero")
        XCTAssertEqual(content.edgeCases[0].category, .edge)

        XCTAssertEqual(content.errorCases.count, 1)
        XCTAssertEqual(content.errorCases[0].input, "nil")
        XCTAssertEqual(content.errorCases[0].expected, "ValueError")
        XCTAssertEqual(content.errorCases[0].reasoning, "reject missing input")
        XCTAssertEqual(content.errorCases[0].category, .error)

        XCTAssertEqual(content.rawContent, fixture)
    }

    func testParseTestsEmptyInputYieldsEmptyStructure() {
        let content = SectionParser.parseTests("")

        XCTAssertTrue(content.baseCases.isEmpty)
        XCTAssertTrue(content.edgeCases.isEmpty)
        XCTAssertTrue(content.errorCases.isEmpty)
        XCTAssertEqual(content.rawContent, "")
        XCTAssertTrue(content.isEmpty)
    }

    // MARK: - parseComplexity

    func testParseComplexityWithInlineHeaderContent() {
        let fixture = """
        ## Complexity

        **Time:** O(n)
        Each character is visited at most twice.

        **Space:** O(k)
        The dictionary holds one entry per distinct character.

        **Trade-off:** We trade memory for speed.
        """

        let content = SectionParser.parseComplexity(fixture)

        XCTAssertEqual(content.time?.notation, "O(n)")
        XCTAssertEqual(content.time?.breakdown, "Each character is visited at most twice.")
        XCTAssertEqual(content.time?.type, .time)

        XCTAssertEqual(content.space?.notation, "O(k)")
        XCTAssertEqual(content.space?.breakdown, "The dictionary holds one entry per distinct character.")
        XCTAssertEqual(content.space?.type, .space)

        XCTAssertEqual(content.tradeOff, "We trade memory for speed.")
        XCTAssertEqual(content.rawContent, fixture)
    }

    func testParseComplexityNotationInsideBoldHeaderIsNotExtracted() {
        // Quirk freeze: the solve prompt asks for "**Time: O(n)**" but the
        // extractor normalizes that header to "time: o(n)", which matches
        // neither "time" nor the "time " prefix. Current behavior drops it.
        let fixture = """
        **Time: O(n)**
        Linear pass over the input.

        **Space: O(1)**
        Constant extra storage.
        """

        let content = SectionParser.parseComplexity(fixture)

        XCTAssertNil(content.time)
        XCTAssertNil(content.space)
        XCTAssertNil(content.tradeOff)
        XCTAssertEqual(content.rawContent, fixture)
        XCTAssertTrue(content.isEmpty)
    }

    func testParseComplexityEmptyInputYieldsEmptyStructure() {
        let content = SectionParser.parseComplexity("")

        XCTAssertNil(content.time)
        XCTAssertNil(content.space)
        XCTAssertNil(content.tradeOff)
        XCTAssertTrue(content.isEmpty)
    }

    // MARK: - parseCodeLink

    func testParseCodeLinkExtractsFirstLabel() {
        let text = "**Step 2 [-> code: window-slide]:** Move the pointers forward"
        XCTAssertEqual(SectionParser.parseCodeLink(from: text), "window-slide")
    }

    func testParseCodeLinkTrimsWhitespaceInsideLabel() {
        XCTAssertEqual(SectionParser.parseCodeLink(from: "[->code:  setup  ]"), "setup")
    }

    func testParseCodeLinkReturnsNilWithoutLink() {
        XCTAssertNil(SectionParser.parseCodeLink(from: "No link marker present in this text"))
        XCTAssertNil(SectionParser.parseCodeLink(from: ""))
    }
}
