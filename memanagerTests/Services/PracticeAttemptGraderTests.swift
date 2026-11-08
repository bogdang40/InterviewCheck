import XCTest
@testable import memanager

final class PracticeAttemptGraderTests: XCTestCase {
    private let grader = PracticeAttemptGrader()

    func testEmptyAttemptFallsBackToBlackout() {
        let evaluation = grader.evaluate(
            card: makeCard(),
            attemptTranscript: "   "
        )

        XCTAssertEqual(evaluation.grade, .blackout)
        XCTAssertEqual(evaluation.confidence, 95)
        XCTAssertEqual(evaluation.attemptTranscript, "")
        XCTAssertTrue(evaluation.feedback.contains("No spoken attempt"))
    }

    func testGroundedAttemptPassesWithEvidenceAndVerificationLanguage() {
        let attempt = """
        I would use BFS because it visits nodes in non-decreasing distance from the source. \
        The invariant is that every queued node has the shortest known distance, and the \
        trade is memory for predictable breadth traversal. I would verify it with a disconnected \
        graph test, a single source test, and an edge case where two paths reach the same node.
        """

        let evaluation = grader.evaluate(
            card: makeCard(),
            attemptTranscript: attempt
        )

        XCTAssertEqual(evaluation.grade, .perfect)
        XCTAssertGreaterThanOrEqual(evaluation.confidence, 38)
        XCTAssertTrue(evaluation.feedback.contains("anchored on the card evidence"))
    }

    private func makeCard() -> PracticeCard {
        PracticeCard(
            sessionID: "session-1",
            topicTag: "graphs",
            prompt: "Explain the BFS invariant and how you would verify it.",
            idealReasoning: "BFS visits nodes in non-decreasing distance from the source and maintains the shortest known distance for each queued node.",
            transcriptSnippet: "I would use BFS for shortest path in an unweighted graph.",
            candidateAttemptSummary: "Needed help naming the invariant.",
            difficulty: .medium,
            sourceEvidence: .manual
        )
    }
}
