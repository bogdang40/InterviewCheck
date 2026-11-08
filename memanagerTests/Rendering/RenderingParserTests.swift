import SwiftUI
import XCTest
@testable import memanager

final class CodeBlockParserTests: XCTestCase {
    func testParsesFencedBlockWithLanguage() {
        let text = "Intro\n```swift\nlet x = 1\n```\nOutro"

        let blocks = CodeBlockParser.parse(text)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.language, "swift")
        XCTAssertTrue(blocks.first?.code.contains("let x = 1") == true)
    }

    func testTildeFencesParse() {
        let text = "~~~python\nprint(1)\n~~~"

        let blocks = CodeBlockParser.parse(text)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.language, "python")
    }

    func testNoFencesFallsBackToWholeTextAsOneUnlabeledBlock() {
        let blocks = CodeBlockParser.parse("just prose, no code")

        XCTAssertEqual(blocks.count, 1)
        XCTAssertNil(blocks.first?.language)
        XCTAssertEqual(blocks.first?.code, "just prose, no code")
    }

    func testStripCodeBlockMarkersRemovesFences() {
        let stripped = CodeBlockParser.stripCodeBlockMarkers("```swift\nlet x = 1\n```")

        XCTAssertFalse(stripped.contains("```"))
        XCTAssertTrue(stripped.contains("let x = 1"))
    }
}

final class TokenAwareHighlighterTests: XCTestCase {
    private func foregroundColors(in attributed: AttributedString, matching substring: String) -> [Color?] {
        let plain = String(attributed.characters)
        guard let range = plain.range(of: substring),
              let attributedRange = Range(range, in: attributed) else {
            XCTFail("Missing expected text: \(substring)")
            return []
        }
        return attributed[attributedRange].runs.map { $0.swiftUI.foregroundColor }
    }

    func testKeywordGetsHighlighted() {
        let attributed = TokenAwareHighlighter.highlight(code: "func greet() {}", language: "swift")

        let keywordColors = foregroundColors(in: attributed, matching: "func")
        XCTAssertEqual(keywordColors, [OverlayPalette.speaker(3)])
    }

    func testKeywordInsideStringLiteralIsNotKeywordColored() {
        let code = "let s = \"func inside string\""
        let attributed = TokenAwareHighlighter.highlight(code: code, language: "swift")

        // The whole literal (including the word func) must share the string
        // run color, distinct from the keyword color of the leading `let`.
        let letColors = foregroundColors(in: attributed, matching: "let")
        let literalRuns = foregroundColors(in: attributed, matching: "\"func inside string\"")
        XCTAssertEqual(letColors, [OverlayPalette.speaker(3)])
        XCTAssertEqual(literalRuns, [OverlayPalette.success])
    }

    func testKeywordsRespectIdentifierBoundariesAndCommentPrecedence() {
        let code = "let letter = 42 // return 123\nlet café = \"你好 🌍\""
        let attributed = TokenAwareHighlighter.highlight(code: code, language: "SWIFT")

        XCTAssertEqual(String(attributed.characters), code)
        XCTAssertEqual(foregroundColors(in: attributed, matching: "letter"), [nil])
        XCTAssertEqual(foregroundColors(in: attributed, matching: "return 123"), [OverlayPalette.textTertiary])
        XCTAssertEqual(foregroundColors(in: attributed, matching: "42"), [OverlayPalette.warning])
        XCTAssertEqual(foregroundColors(in: attributed, matching: "你好 🌍"), [OverlayPalette.success])
    }

    func testLanguageAliasesUseTheirKeywordVocabulary() {
        let samples: [([String], String)] = [
            (["swift"], "func"),
            (["python", "py"], "def"),
            (["javascript", "js", "typescript", "ts"], "function"),
            (["rust"], "impl"),
            (["go", "golang"], "defer"),
            (["cpp", "c++", "cc", "cxx", "hpp", "c", "h"], "constexpr"),
            (["java"], "implements"),
            (["csharp", "cs", "c#"], "foreach"),
            (["kotlin", "kt", "kts"], "suspend")
        ]
        for (languages, keyword) in samples {
            for language in languages {
                let attributed = TokenAwareHighlighter.highlight(code: keyword, language: language)
                XCTAssertEqual(foregroundColors(in: attributed, matching: keyword), [OverlayPalette.speaker(3)], language)
            }
        }
    }

    func testUnknownLanguageStillReturnsText() {
        let attributed = TokenAwareHighlighter.highlight(code: "SELECT 1", language: "brainfudge")

        XCTAssertEqual(String(attributed.characters), "SELECT 1")
    }
}

final class FencedMarkdownRenderingLayerTests: XCTestCase {
    func testSplitsTextAndCodeSegments() {
        let text = "Before\n\n```mermaid\nflowchart TD\n    A --> B\n```\n\nAfter"

        let segments = FencedMarkdownParser.parse(text)

        XCTAssertEqual(segments.count, 3)
        guard case .text(let before) = segments[0].kind,
              case .code(let hint, let code) = segments[1].kind,
              case .text(let after) = segments[2].kind else {
            return XCTFail("Unexpected segment shapes: \(segments)")
        }
        XCTAssertTrue(before.contains("Before"))
        XCTAssertEqual(FencedMarkdownLanguageClassifier.primaryLanguage(from: hint), "mermaid")
        XCTAssertTrue(code.contains("flowchart"))
        XCTAssertTrue(after.contains("After"))
    }

    func testPlainTextIsOneSegment() {
        let segments = FencedMarkdownParser.parse("no code here")

        XCTAssertEqual(segments.count, 1)
        guard case .text = segments[0].kind else {
            return XCTFail("Expected a single text segment")
        }
    }

    func testMermaidClassifierMatchesAliases() {
        XCTAssertTrue(FencedMarkdownLanguageClassifier.isMermaidLanguage("mermaid"))
        XCTAssertTrue(FencedMarkdownLanguageClassifier.isMermaidLanguage("mmd"))
        XCTAssertFalse(FencedMarkdownLanguageClassifier.isMermaidLanguage("swift"))
        XCTAssertFalse(FencedMarkdownLanguageClassifier.isMermaidLanguage(nil))
    }
}
