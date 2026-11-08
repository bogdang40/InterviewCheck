import XCTest
@testable import memanager

final class QuickAssistSayFirstExtractorTests: XCTestCase {

    private func extract(_ text: String) -> QuickAssistSayFirstExtractor.Extraction {
        QuickAssistSayFirstExtractor.extract(from: QuickAssistSectionParser.parse(text))
    }

    func testExtractsOpenerAndDropsEmptyLeadingSection() {
        let response = """
        **Say first:** Good question, the tension here is speed against durability.

        ### Situation
        We were two weeks from launch when the pipeline broke.

        ### Action
        I bisected the deploy history and found the bad migration.
        """

        let extraction = extract(response)

        XCTAssertEqual(extraction.opener, "Good question, the tension here is speed against durability.")
        XCTAssertEqual(extraction.sections.count, 2)
        XCTAssertEqual(extraction.sections.first?.title, "Situation")
    }

    func testKeepsTrailingProseOfLeadingSection() {
        let response = """
        **Say first:** Let me anchor on the numbers first.
        The rest of this paragraph stays in the body.

        ### Estimate
        Round to one hundred million users.
        """

        let extraction = extract(response)

        XCTAssertEqual(extraction.opener, "Let me anchor on the numbers first.")
        XCTAssertEqual(extraction.sections.count, 2)
        guard case .markdown(_, let text)? = extraction.sections.first?.contentBlocks.first else {
            return XCTFail("Expected markdown remainder")
        }
        XCTAssertEqual(text, "The rest of this paragraph stays in the body.")
    }

    func testNoOpenerPassesSectionsThroughUnchanged() {
        let response = """
        ### Approach
        Sliding window with a char index map.
        """

        let extraction = extract(response)

        XCTAssertNil(extraction.opener)
        XCTAssertEqual(extraction.sections.count, 1)
        XCTAssertEqual(extraction.sections.first?.title, "Approach")
    }

    func testPlainResponseWithoutLabelIsUntouched() {
        let extraction = extract("So my approach here is a two pointer sweep from both ends.")

        XCTAssertNil(extraction.opener)
        XCTAssertEqual(extraction.sections.count, 1)
    }

    func testEmptyOpenerLineIsIgnored() {
        let extraction = extract("**Say first:**\n\n### Beat\nContent here.")

        XCTAssertNil(extraction.opener)
    }
}
