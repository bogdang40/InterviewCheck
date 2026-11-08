import XCTest
@testable import memanager

final class StreamingBlockSegmenterTests: XCTestCase {
    func testBoundarySitsAfterLastCompletedParagraph() {
        let draft = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph still typ"

        let segmentation = StreamingBlockSegmenter.segment(draft: draft, previousCommittedLength: 0)

        XCTAssertEqual(segmentation.committedText, "First paragraph.\n\nSecond paragraph.\n\n")
        XCTAssertEqual(segmentation.tailText, "Third paragraph still typ")
    }

    func testUnterminatedMermaidFenceStaysEntirelyInTail() {
        let draft = "Intro paragraph.\n\n```mermaid\nflowchart TD\n    A --> B\n"

        let segmentation = StreamingBlockSegmenter.segment(draft: draft, previousCommittedLength: 0)

        XCTAssertEqual(segmentation.committedText, "Intro paragraph.\n\n")
        XCTAssertTrue(segmentation.tailText.hasPrefix("```mermaid"), "The open fence must stream raw")
    }

    func testClosedFenceCanCommit() {
        let draft = "Intro.\n\n```swift\nlet x = 1\n```\n\nNext paragraph typ"

        let segmentation = StreamingBlockSegmenter.segment(draft: draft, previousCommittedLength: 0)

        XCTAssertEqual(segmentation.committedText, "Intro.\n\n```swift\nlet x = 1\n```\n\n")
        XCTAssertEqual(segmentation.tailText, "Next paragraph typ")
    }

    func testCommittedLengthNeverRegresses() {
        let longerCommit = "A.\n\nB.\n\n"
        let draft = longerCommit + "tail"

        let segmentation = StreamingBlockSegmenter.segment(
            draft: draft,
            previousCommittedLength: longerCommit.count + 2
        )

        XCTAssertEqual(segmentation.committedLength, longerCommit.count + 2,
                       "A previously larger commitment holds even when the boundary heuristic would shrink it")
    }

    func testSettleForcesFullCommitment() {
        let draft = "Paragraph one.\n\n```mermaid\nflowchart TD\n    A --> B\n```"

        let settled = StreamingBlockSegmenter.segment(draft: draft, previousCommittedLength: draft.count)

        XCTAssertEqual(settled.committedText, draft)
        XCTAssertTrue(settled.tailText.isEmpty)
    }

    func testCommittedPrefixSectionsStayOrdinallyStableAsDraftGrows() {
        let stage1 = "## Setup\n\nUse a queue.\n\n"
        let stage2 = stage1 + "## Details\n\nDrain it in order.\n\n"

        let sections1 = QuickAssistSectionParser.parse(
            StreamingBlockSegmenter.segment(draft: stage1, previousCommittedLength: 0).committedText
        )
        let sections2 = QuickAssistSectionParser.parse(
            StreamingBlockSegmenter.segment(draft: stage2, previousCommittedLength: stage1.count).committedText
        )

        XCTAssertEqual(sections1.first?.title, sections2.first?.title,
                       "The first committed section must survive the draft growing")
        XCTAssertEqual(sections1.first?.id, sections2.first?.id,
                       "Ordinal ids keep the committed prefix diffable in place")
    }
}
