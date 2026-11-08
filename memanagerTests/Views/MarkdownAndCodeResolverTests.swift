import SwiftUI
import XCTest
@testable import memanager

final class MarkdownAndCodeResolverTests: XCTestCase {

    // MARK: Code lines

    func testHighlightedCodeSplitsIntoNumberedLinesKeepingRuns() {
        let code = "let a = \"x\"\n// note\nreturn a"
        let highlighted = TokenAwareHighlighter.highlight(code: code, language: "swift")

        let lines = CodeLineResolver.lines(from: highlighted, newRange: 2...3)

        XCTAssertEqual(lines.map(\.number), [1, 2, 3])
        XCTAssertEqual(lines.map { String($0.text.characters) }, ["let a = \"x\"", "// note", "return a"])
        XCTAssertEqual(lines.map(\.isNew), [false, true, true])
        XCTAssertTrue(lines[0].text.runs.count > 1, "keyword and string runs must survive the split")
    }

    func testPlainCodeKeepsTrailingEmptyLine() {
        let lines = CodeLineResolver.lines(from: "a\n", newRange: nil)

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].text.characters.isEmpty)
    }

    func testGutterAndNewLinesLabel() {
        XCTAssertEqual(CodeLineResolver.gutterDigits(lineCount: 3), 2)
        XCTAssertEqual(CodeLineResolver.gutterDigits(lineCount: 120), 3)
        XCTAssertNil(CodeLineResolver.newLinesLabel(for: nil))
        XCTAssertEqual(CodeLineResolver.newLinesLabel(for: 4...4), "Line 4 new")
        XCTAssertEqual(CodeLineResolver.newLinesLabel(for: 4...9), "Lines 4 to 9 new")
    }

    // MARK: Highlighter catalog

    func testCataloguedLanguagesHighlightKeywords() {
        let samples: [(String, String, String)] = [
            ("cpp", "int main() { return 0; }", "return"),
            ("java", "public static void main() {}", "static"),
            ("csharp", "public async Task Run() {}", "async"),
            ("kotlin", "fun main() { val x = 1 }", "val")
        ]
        for (language, code, keyword) in samples {
            let attributed = TokenAwareHighlighter.highlight(code: code, language: language)
            let colored = attributed.runs.contains { run in
                String(attributed.characters[run.range]).contains(keyword) && run.swiftUI.foregroundColor != nil
            }
            XCTAssertTrue(colored, "\(language) should color \(keyword)")
        }
    }

    // MARK: Markdown blocks

    private func parse(_ markdown: String) -> [MarkdownBlock] {
        MarkdownText.makeBlocks(from: markdown)
    }

    func testMarkdownBlocksRebuildStructureFromIntents() {
        let blocks = parse("# Title\n\nBody with `code`.\n\n- one\n- two\n\n1. first\n\n> quote")

        XCTAssertEqual(blocks.count, 6)
        XCTAssertEqual(blocks[0].kind, .heading(level: 1))
        XCTAssertEqual(blocks[1].kind, .paragraph)
        XCTAssertEqual(blocks[2].kind, .listItem(marker: MarkdownBlockResolver.bulletMarker, depth: 1))
        XCTAssertEqual(blocks[3].kind, .listItem(marker: MarkdownBlockResolver.bulletMarker, depth: 1))
        XCTAssertEqual(blocks[4].kind, .listItem(marker: "1.", depth: 1))
        XCTAssertEqual(blocks[5].kind, .blockQuote)
        XCTAssertEqual(String(blocks[5].content.characters), "quote")
    }

    func testNestedListItemsCarryDepth() {
        let blocks = parse("- outer\n  - inner")

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[1].kind, .listItem(marker: MarkdownBlockResolver.bulletMarker, depth: 2))
    }

    func testPlainProseIsOneParagraph() {
        let blocks = parse("just a sentence")

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .paragraph)
    }

    func testInlineCodeAndLinksAreStyled() {
        let styled = MarkdownText.makeAttributedString(from: "see `x` and [docs](https://example.test)")

        let codeRun = styled.runs.first { String(styled.characters[$0.range]) == "x" }
        let linkRun = styled.runs.first { String(styled.characters[$0.range]) == "docs" }
        XCTAssertEqual(codeRun?.swiftUI.font, OverlayType.mono)
        XCTAssertNotNil(codeRun?.swiftUI.backgroundColor)
        XCTAssertNotNil(linkRun?.link)
        XCTAssertEqual(linkRun?.swiftUI.foregroundColor, OverlayPalette.accent)
    }

    func testMarkdownBlocksAreMemoized() {
        let markdown = "# Same\n\ninput"

        let first = MarkdownText.makeBlocks(from: markdown)
        let second = MarkdownText.makeBlocks(from: markdown)

        XCTAssertEqual(first, second)
    }
}
