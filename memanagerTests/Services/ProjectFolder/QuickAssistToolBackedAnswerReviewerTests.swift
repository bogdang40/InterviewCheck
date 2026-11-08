import XCTest
@testable import memanager

final class QuickAssistToolBackedAnswerReviewerTests: XCTestCase {
    private let reviewer = QuickAssistToolBackedAnswerReviewer()

    func testReviewerFlagsToolBackedAnswerWithoutCitationsOrCodeBlock() {
        let trace = QuickAssistToolTrace(
            turnID: UUID(),
            steps: [
                QuickAssistToolTraceStep(
                    id: "read",
                    toolName: "read_file",
                    state: .completed,
                    iteration: 1,
                    displayInput: "read_file\npath: memanager/Services/SessionController.swift",
                    rawArgumentsJSON: #"{"path":"memanager/Services/SessionController.swift"}"#,
                    resultContent: "    40  final class SessionController {",
                    contentTruncated: false,
                    overflowPath: nil,
                    startedAt: Date(),
                    durationMs: 8,
                    evidenceKind: .read(
                        QuickAssistToolReadExcerpt(
                            path: "memanager/Services/SessionController.swift",
                            startLine: 40,
                            endLine: 42,
                            snippet: "40: final class SessionController {"
                        )
                    ),
                    referencedFiles: [
                        QuickAssistToolFileReference(
                            path: "memanager/Services/SessionController.swift",
                            lines: [40, 41, 42]
                        )
                    ]
                )
            ]
        )

        let review = reviewer.review(
            responseText: "I would update the shared controller initialization to avoid duplicate state.",
            trace: trace
        )

        XCTAssertTrue(review.needsRevision)
        XCTAssertEqual(review.shouldMarkNeedsReview, true)
    }

    func testReviewerAcceptsCitedAnswerWithCodeBlock() {
        let trace = QuickAssistToolTrace(
            turnID: UUID(),
            steps: [
                QuickAssistToolTraceStep(
                    id: "search",
                    toolName: "search_files",
                    state: .completed,
                    iteration: 1,
                    displayInput: "search_files\npattern: SessionController",
                    rawArgumentsJSON: #"{"pattern":"SessionController"}"#,
                    resultContent: "memanager/Services/SessionController.swift:40: final class SessionController {",
                    contentTruncated: false,
                    overflowPath: nil,
                    startedAt: Date(),
                    durationMs: 8,
                    evidenceKind: .search(
                        pattern: "SessionController",
                        scopePath: nil,
                        groups: [
                            QuickAssistToolSearchGroup(
                                path: "memanager/Services/SessionController.swift",
                                lines: [QuickAssistToolSearchMatchLine(lineNumber: 40, text: "final class SessionController {", isContext: false)]
                            )
                        ]
                    ),
                    referencedFiles: [
                        QuickAssistToolFileReference(
                            path: "memanager/Services/SessionController.swift",
                            lines: [40]
                        )
                    ]
                )
            ]
        )

        let review = reviewer.review(
            responseText: """
            In `memanager/Services/SessionController.swift:40` the controller singleton is declared here:

            ```swift
            final class SessionController {
                static let shared = SessionController()
            }
            ```
            """,
            trace: trace
        )

        XCTAssertFalse(review.needsRevision)
        XCTAssertNil(review.reason)
    }
}
