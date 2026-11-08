import XCTest
@testable import memanager

/// Characterization ("golden") tests that freeze the CURRENT behavior of
/// MentorResponse.parse(from:) before refactoring. Expectations mirror what
/// the current code produces; never "fix" production code to satisfy them.
final class MentorResponseParseGoldenTests: XCTestCase {

    // MARK: - Multi-section parsing

    func testParseMultiSectionResponsePopulatesEachSection() {
        let fixture = """
        Preamble before any header is dropped.

        ## Problem
        The problem statement.

        ## Clarifying Questions
        Edge case questions here.

        ## Implementation
        Implementation walkthrough.

        ## Tests
        `1` -> `2` (base case)

        ## Complexity
        Time is linear.

        ## System Design
        Design notes.
        """

        let response = MentorResponse.parse(from: fixture)

        XCTAssertEqual(response.problem, "The problem statement.")
        XCTAssertEqual(response.clarifyingQuestions, "Edge case questions here.")
        XCTAssertEqual(response.implementation, "Implementation walkthrough.")
        XCTAssertEqual(response.tests, "`1` -> `2` (base case)")
        XCTAssertEqual(response.complexity, "Time is linear.")
        XCTAssertEqual(response.systemDesign, "Design notes.")

        // Text before the first recognized header is discarded entirely.
        XCTAssertFalse(response.problem.contains("Preamble"))
    }

    // MARK: - Approach synonym behavior

    func testApproachHeaderContentFoldsIntoImplementationSection() {
        // "approach" maps to the .implementation section, so a later
        // "## Approach" header appends its lines to the same bucket.
        let fixture = """
        ## Implementation
        Core implementation prose.

        ## Approach
        Approach prose that folds into implementation.
        """

        let response = MentorResponse.parse(from: fixture)

        XCTAssertEqual(
            response.implementation,
            "Core implementation prose.\n\nApproach prose that folds into implementation."
        )
    }

    func testSoloApproachHeaderMapsToImplementation() {
        let response = MentorResponse.parse(from: "## Approach\nGreedy two pointer walk.")

        XCTAssertEqual(response.implementation, "Greedy two pointer walk.")
        XCTAssertEqual(response.problem, "")
    }

    func testBoldApproachAndSolutionSynonymsMapToImplementation() {
        // Bold header form.
        let bold = MentorResponse.parse(from: "**Approach**\nBold approach body.")
        XCTAssertEqual(bold.implementation, "Bold approach body.")

        // "solution" is also an implementation synonym.
        let solution = MentorResponse.parse(from: "## Solution\nSolution body.")
        XCTAssertEqual(solution.implementation, "Solution body.")

        // A bare line equal to a known header title also switches sections.
        let plain = MentorResponse.parse(from: "Approach\nPlain header body.")
        XCTAssertEqual(plain.implementation, "Plain header body.")
    }

    // MARK: - Degenerate inputs

    func testParseHeaderlessTextYieldsEmptyResponse() {
        let response = MentorResponse.parse(from: "No headers at all, just loose prose.")

        XCTAssertEqual(response.problem, "")
        XCTAssertEqual(response.clarifyingQuestions, "")
        XCTAssertEqual(response.implementation, "")
        XCTAssertEqual(response.tests, "")
        XCTAssertEqual(response.complexity, "")
        XCTAssertEqual(response.systemDesign, "")
    }

    func testParseEmptyStringYieldsEmptyResponse() {
        let response = MentorResponse.parse(from: "")

        XCTAssertEqual(response.problem, "")
        XCTAssertEqual(response.implementation, "")
        XCTAssertEqual(response.systemDesign, "")
    }
}
