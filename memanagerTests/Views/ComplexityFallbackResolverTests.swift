import XCTest
@testable import memanager

final class ComplexityFallbackResolverTests: XCTestCase {
    func testRecoversNotationInsideBoldLabels() {
        let raw = """
        **Time: O(n)** Each index is visited once.

        **Space: O(k)** where k is the alphabet size.

        **Trade-off:** A set is simpler but slower.
        """

        let content = ComplexityFallbackResolver.recover(from: raw)

        XCTAssertEqual(content?.time?.notation, "O(n)")
        XCTAssertEqual(content?.time?.breakdown, "Each index is visited once.")
        XCTAssertEqual(content?.space?.notation, "O(k)")
        XCTAssertEqual(content?.space?.breakdown, "where k is the alphabet size.")
        XCTAssertEqual(content?.tradeOff, "A set is simpler but slower.")
        XCTAssertEqual(content?.rawContent, raw)
    }

    func testRecoversMultiLineEntriesAndInlineLabels() {
        let raw = """
        ## Complexity
        **Time:** O(n log n)
        Sort once, then scan.
        **Space:** O(1)
        """

        let content = ComplexityFallbackResolver.recover(from: raw)

        XCTAssertEqual(content?.time?.notation, "O(n log n)")
        XCTAssertEqual(content?.time?.breakdown, "Sort once, then scan.")
        XCTAssertEqual(content?.space?.notation, "O(1)")
        XCTAssertEqual(content?.space?.breakdown, "")
        XCTAssertNil(content?.tradeOff)
    }

    func testMissingNotationStaysUnstated() {
        let content = ComplexityFallbackResolver.recover(from: "**Time:** linear in the input")

        XCTAssertEqual(content?.time?.notation, "")
        XCTAssertFalse(ComplexityNotationPresenter.isStated(content?.time?.notation ?? ""))
    }

    func testProseWithoutLabelsIsNotRecovered() {
        XCTAssertNil(ComplexityFallbackResolver.recover(from: "It runs fast enough for the given limits."))
    }

    func testResolveKeepsParsedContentUntouched() {
        let parsed = ComplexityContent(
            time: ComplexityAnalysis(notation: "O(1)", breakdown: "", type: .time),
            space: nil,
            tradeOff: nil,
            rawContent: "**Time: O(n)**"
        )

        XCTAssertEqual(ComplexityFallbackResolver.resolve(parsed).time?.notation, "O(1)")
    }
}
