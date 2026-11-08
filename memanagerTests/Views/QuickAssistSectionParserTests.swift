import XCTest
@testable import memanager

final class QuickAssistSectionParserTests: XCTestCase {
    func testParserBuildsSectionsWithHeadingsSubtitlesAndCodeBlocks() {
        let response = """
        ## Problem
        *Find the right approach quickly.*

        We should use a hash map to avoid nested loops.

        ```swift
        let values = [1, 2, 3]
        ```

        ## Architecture:
        ```mermaid
        flowchart TD
            A[Client] --> B[API]
            B --> C[DB]
        ```
        """

        let sections = QuickAssistSectionParser.parse(response)
        XCTAssertEqual(sections.count, 2)

        XCTAssertEqual(sections[0].title, "Problem")
        XCTAssertEqual(sections[0].subtitle, "Find the right approach quickly.")
        XCTAssertEqual(sections[0].contentBlocks.count, 2)

        guard case .markdown(_, let firstBody) = sections[0].contentBlocks[0] else {
            return XCTFail("Expected markdown body in first section")
        }
        XCTAssertTrue(firstBody.contains("hash map"))

        guard case .code(_, let firstLanguage, let firstCode) = sections[0].contentBlocks[1] else {
            return XCTFail("Expected code block in first section")
        }
        XCTAssertEqual(firstLanguage, "swift")
        XCTAssertTrue(firstCode.contains("let values"))

        XCTAssertEqual(sections[1].title, "Architecture")
        XCTAssertNil(sections[1].subtitle)
        XCTAssertEqual(sections[1].contentBlocks.count, 1)

        guard case .code(_, let secondLanguage, let secondCode) = sections[1].contentBlocks[0] else {
            return XCTFail("Expected code block in second section")
        }
        XCTAssertEqual(secondLanguage, "mermaid")
        XCTAssertTrue(secondCode.contains("flowchart TD"))
    }

    func testParserFallsBackToSingleSectionForPlainText() {
        let response = """
        I would start with a quick restatement of the problem.

        Then I would propose a direct implementation.
        """

        let sections = QuickAssistSectionParser.parse(response)
        XCTAssertEqual(sections.count, 1)
        XCTAssertNil(sections[0].title)
        XCTAssertEqual(sections[0].contentBlocks.count, 1)
        XCTAssertEqual(sections[0].contentBlocks[0].presentationKind, .prose)

        guard case .markdown(_, let text) = sections[0].contentBlocks[0] else {
            return XCTFail("Expected markdown fallback block")
        }
        XCTAssertTrue(text.contains("quick restatement"))
    }

    func testPresentationKindDistinguishesMarkdownCodeAndMermaid() {
        let response = """
        ## Answer
        Start with a short summary.

        ```swift
        let answer = 42
        ```

        ```mermaid
        flowchart LR
            A[Question] --> B[Answer]
        ```
        """

        let sections = QuickAssistSectionParser.parse(response)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].contentBlocks.map(\.presentationKind), [.prose, .code, .mermaid])
    }

    func testMarkdownPreserveWhitespaceModeRetainsBulletsAndNewlines() {
        let markdown = """
        - First bullet
        - Second bullet

        Follow-up line.
        """

        let rendered = String(
            MarkdownText.makeAttributedString(
                from: markdown,
                renderMode: .preserveWhitespace
            ).characters
        )

        // preserveWhitespace mode swaps literal list markers for real
        // bullet glyphs while keeping line structure intact.
        XCTAssertTrue(rendered.contains("\u{2022} First bullet"))
        XCTAssertTrue(rendered.contains("\n\u{2022} Second bullet"))
        XCTAssertTrue(rendered.contains("\n\nFollow-up line."))
    }

    func testMarkdownPreserveWhitespaceModeRetainsStarSectionLineBreaks() {
        let response = """
        Situation:
        Production quick assists were hard to scan.

        Task:
        Keep STAR+ spacing intact after final render.

        Action:
        Route the final renderer through whitespace-preserving markdown.

        Result:
        Section lines stay readable instead of collapsing.

        Reflection:
        Preserve layout first, style second.
        """

        let rendered = String(
            MarkdownText.makeAttributedString(
                from: response,
                renderMode: .preserveWhitespace
            ).characters
        )

        XCTAssertTrue(rendered.contains("Situation:\nProduction quick assists were hard to scan."))
        XCTAssertTrue(rendered.contains("Task:\nKeep STAR+ spacing intact after final render."))
        XCTAssertTrue(rendered.contains("Action:\nRoute the final renderer through whitespace-preserving markdown."))
        XCTAssertTrue(rendered.contains("Result:\nSection lines stay readable instead of collapsing."))
        XCTAssertTrue(rendered.contains("Reflection:\nPreserve layout first, style second."))
    }
}
