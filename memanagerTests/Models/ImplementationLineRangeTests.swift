import XCTest
@testable import memanager

final class ImplementationLineRangeTests: XCTestCase {
    func testInvalidGeneratedRangesFallBackToAvailableCode() throws {
        for marker in ["9-2", "0-2", "999999999999999999999999", "99-100"] {
            let step = try parseStep(marker: marker)
            XCTAssertEqual(step.addedLineRange, 1...3, marker)
            XCTAssertEqual(step.codeSnippet, "first\nsecond\nthird", marker)
        }
    }

    func testExplicitRangeOnlyIncludesMarkedLines() throws {
        let step = try parseStep(marker: "2-2")
        XCTAssertEqual(step.addedLineRange, 2...2)
        XCTAssertEqual(step.codeSnippet, "second")
        XCTAssertEqual(step.cumulativeCode, "first\nsecond\nthird")
    }

    func testExplicitRangeIsBoundedByAvailableLines() throws {
        let step = try parseStep(marker: "2-999999999")
        XCTAssertEqual(step.addedLineRange, 2...3)
        XCTAssertEqual(step.codeSnippet, "second\nthird")
    }

    private func parseStep(marker: String) throws -> ImplementationStep {
        let parsed = SectionParser.parseImplementation("""
        ### Step 1: Build the result
        Keep the complete code visible.
        ```python
        # NEW: lines \(marker)
        first
        second
        third
        ```
        """)
        return try XCTUnwrap(parsed.steps.first)
    }
}
