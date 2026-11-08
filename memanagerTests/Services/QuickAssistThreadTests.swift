import XCTest
@testable import memanager

final class QuickAssistThreadTests: XCTestCase {
    func testAppendTurnKeepsAllTurnsWithoutCap() {
        let thread = QuickAssistThread()

        for index in 0..<25 {
            thread.appendTurn(QuickAssistThread.Turn(
                id: UUID(),
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                transcriptDelta: "Transcript \(index)",
                question: "Q\(index)",
                response: "R\(index)",
                contextMode: .conversation,
                modelTier: .fast
            ))
        }

        XCTAssertEqual(thread.turnCount, 25)
        XCTAssertEqual(thread.turns.first?.question, "Q0")
        XCTAssertEqual(thread.turns.last?.question, "Q24")
    }

    func testReplaceTurnsHydratesThreadState() {
        let thread = QuickAssistThread()
        let hydratedTurns = [
            QuickAssistThread.Turn(
                id: UUID(),
                timestamp: Date(timeIntervalSince1970: 1),
                transcriptDelta: "Me: first",
                question: "question 1",
                response: "answer 1",
                contextMode: .conversation,
                modelTier: .fast
            ),
            QuickAssistThread.Turn(
                id: UUID(),
                timestamp: Date(timeIntervalSince1970: 2),
                transcriptDelta: "Me: second",
                question: "question 2",
                response: "answer 2",
                contextMode: .allSectionsContext,
                modelTier: .deep,
                questionSource: .auto
            )
        ]

        thread.replaceTurns(hydratedTurns)

        XCTAssertEqual(thread.turnCount, 2)
        XCTAssertEqual(thread.lastResponse, "answer 2")
        XCTAssertEqual(thread.lastModelTier, .deep)
        XCTAssertEqual(thread.turns.last?.questionSource, .auto)
    }
}
