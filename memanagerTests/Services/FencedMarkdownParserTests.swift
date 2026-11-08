import XCTest
@testable import memanager

final class FencedMarkdownParserTests: XCTestCase {
    func testParseMixedTextCodeAndMermaidPreservesOrder() {
        let markdown = """
        Intro paragraph.

        ```swift
        let value = 42
        ```

        Transition paragraph.

        ```mermaid
        flowchart TD
            A[Start] --> B[End]
        ```

        Closing paragraph.
        """

        let segments = FencedMarkdownParser.parse(markdown)
        XCTAssertEqual(segments.count, 5)

        guard case .text(let intro) = segments[0].kind else {
            return XCTFail("Expected intro text segment")
        }
        XCTAssertTrue(intro.contains("Intro paragraph"))

        guard case .code(let languageHint, let swiftCode) = segments[1].kind else {
            return XCTFail("Expected swift code segment")
        }
        XCTAssertEqual(languageHint, "swift")
        XCTAssertEqual(swiftCode, "let value = 42")

        guard case .text(let transition) = segments[2].kind else {
            return XCTFail("Expected transition text segment")
        }
        XCTAssertTrue(transition.contains("Transition paragraph"))

        guard case .code(let mermaidHint, let mermaidCode) = segments[3].kind else {
            return XCTFail("Expected mermaid code segment")
        }
        XCTAssertEqual(mermaidHint, "mermaid")
        XCTAssertTrue(mermaidCode.contains("flowchart TD"))

        guard case .text(let closing) = segments[4].kind else {
            return XCTFail("Expected closing text segment")
        }
        XCTAssertTrue(closing.contains("Closing paragraph"))
    }

    func testParseSupportsBacktickAndTildeFences() {
        let markdown = """
        ~~~python
        print("tilde")
        ~~~

        ```swift
        print("backtick")
        ```
        """

        let segments = FencedMarkdownParser.parse(markdown)
        XCTAssertEqual(segments.count, 2)

        guard case .code(let firstHint, let firstCode) = segments[0].kind else {
            return XCTFail("Expected first code segment")
        }
        XCTAssertEqual(firstHint, "python")
        XCTAssertEqual(firstCode, #"print("tilde")"#)

        guard case .code(let secondHint, let secondCode) = segments[1].kind else {
            return XCTFail("Expected second code segment")
        }
        XCTAssertEqual(secondHint, "swift")
        XCTAssertEqual(secondCode, #"print("backtick")"#)
    }

    func testParseReturnsSingleTextSegmentWhenFenceIsUnclosed() {
        let markdown = """
        Here is unfinished code:
        ```swift
        let broken = true
        """

        let segments = FencedMarkdownParser.parse(markdown)
        XCTAssertEqual(segments.count, 1)
        guard case .text(let value) = segments[0].kind else {
            return XCTFail("Expected text fallback segment")
        }
        XCTAssertTrue(value.contains("```swift"))
        XCTAssertTrue(value.contains("let broken = true"))
    }
}

final class FencedMarkdownLanguageClassifierTests: XCTestCase {
    func testMermaidDetectionSupportsCaseAndAliases() {
        XCTAssertTrue(FencedMarkdownLanguageClassifier.isMermaidLanguage("mermaid"))
        XCTAssertTrue(FencedMarkdownLanguageClassifier.isMermaidLanguage("MERMAID"))
        XCTAssertTrue(FencedMarkdownLanguageClassifier.isMermaidLanguage("mmd"))
    }

    func testMermaidDetectionUsesFirstTokenForLanguageHintsWithAttributes() {
        XCTAssertTrue(FencedMarkdownLanguageClassifier.isMermaidLanguage("mermaid {theme=dark}"))
        XCTAssertEqual(
            FencedMarkdownLanguageClassifier.primaryLanguage(from: "swift {linenos=true}"),
            "swift"
        )
        XCTAssertFalse(FencedMarkdownLanguageClassifier.isMermaidLanguage("swift mermaid"))
    }
}

