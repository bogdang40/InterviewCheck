import XCTest
@testable import memanager

final class QuickAssistSourcePresentationTests: XCTestCase {
    func testHistoricalAnswerUsesRecordedContextAndIdentity() throws {
        var state = QuickAssistRenderFixtures.state(
            isLoading: false, selectedResponse: "Historical answer", streamingDraft: nil,
            turnCount: 3, selectedIndex: 0, activeThreadID: "saved-thread"
        )
        var record = try makeRecord(turnID: XCTUnwrap(state.selectedTurnID))
        state.sourceRecord = record
        record.extraContext = "A workspace selected after the answer"
        record.transcriptText = "Later captured speech"

        let snapshot = try savedSnapshot(state.savedSources)
        XCTAssertEqual(snapshot.turnID, state.selectedTurnID?.uuidString)
        XCTAssertEqual(snapshot.threadID, "saved-thread")
        XCTAssertEqual(snapshot.sessionID, "saved-session")
        XCTAssertEqual(snapshot.requestedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(snapshot.question, "Which project supplied this answer?")
        XCTAssertEqual(snapshot.transcript, "Recorded speech\nwith original spacing")
        XCTAssertEqual(snapshot.extraContext, "Workspace: Original project\nRecorded knowledge and notes")
        XCTAssertEqual(snapshot.evidenceManifest, "transcript_len=42\nscreenshot_count=1")
        XCTAssertTrue(snapshot.hasScreenshot)
    }

    func testRecordFromAnotherTurnOrThreadIsNeverShown() throws {
        let selectedID = UUID()
        let otherTurn = makeRecord(turnID: UUID())
        XCTAssertEqual(presentation(turnID: selectedID, record: otherTurn), .unavailable(.missingRecord))
        let otherThread = makeRecord(turnID: selectedID, threadID: "other-thread")
        XCTAssertEqual(presentation(turnID: selectedID, record: otherThread), .unavailable(.missingRecord))
    }

    func testMissingRecordAndNoSelectionRemainDistinct() {
        XCTAssertEqual(presentation(turnID: UUID(), record: nil), .unavailable(.missingRecord))
        XCTAssertEqual(presentation(turnID: nil, record: makeRecord(turnID: UUID())), .unavailable(.noSelection))
    }

    func testLegacyRecordPreservesUnavailableVersusRecordedEmptyFields() throws {
        let turnID = UUID()
        var record = makeRecord(turnID: turnID)
        record.question = nil
        record.transcriptText = nil
        record.extraContext = ""
        let snapshot = try savedSnapshot(presentation(turnID: turnID, record: record))
        XCTAssertNil(snapshot.question)
        XCTAssertNil(snapshot.transcript)
        XCTAssertEqual(snapshot.extraContext, "")
    }

    func testFollowUpRetainsItsOriginalPriorAnswerContext() throws {
        var state = QuickAssistRenderFixtures.state(
            isLoading: false, selectedResponse: "A follow-up answer", streamingDraft: nil,
            activeThreadID: "saved-thread"
        )
        var record = try makeRecord(turnID: XCTUnwrap(state.selectedTurnID))
        state.sourceRecord = record
        record.previousResponse = "A later answer selected in the conversation"

        let snapshot = try savedSnapshot(state.savedSources)
        XCTAssertTrue(snapshot.hasPreviousResponse)
        XCTAssertEqual(snapshot.previousResponse, "Original prior answer\nwith retained context")
        XCTAssertNotEqual(snapshot.previousResponse, state.selectedResponse)
    }

    func testUnavailableAndEmptyPriorAnswersRemainDistinct() throws {
        let turnID = UUID()
        var record = makeRecord(turnID: turnID)
        record.previousResponse = nil
        let unavailable = try savedSnapshot(presentation(turnID: turnID, record: record))
        XCTAssertTrue(unavailable.hasPreviousResponse)
        XCTAssertNil(unavailable.previousResponse)

        record.previousResponse = ""
        let empty = try savedSnapshot(presentation(turnID: turnID, record: record))
        XCTAssertTrue(empty.hasPreviousResponse)
        XCTAssertEqual(empty.previousResponse, "")
    }

    func testAutomaticQuestionRetainsItsInferenceProvenance() throws {
        let turnID = UUID()
        var record = makeRecord(turnID: turnID, questionSource: .auto)
        record.question = "Question inferred from the completed response"

        let inferred = try savedSnapshot(presentation(turnID: turnID, record: record))
        XCTAssertEqual(inferred.questionSource, .auto)
        XCTAssertEqual(inferred.question, record.question)
        let manual = try savedSnapshot(presentation(turnID: turnID, record: makeRecord(turnID: turnID)))
        XCTAssertEqual(manual.questionSource, .manual)
    }

    func testNewStreamingAnswerCannotDisplayPreviousTurnsSources() throws {
        var state = QuickAssistRenderFixtures.state(
            isLoading: true, selectedResponse: "Previous answer", streamingDraft: "New partial answer",
            activeThreadID: "saved-thread"
        )
        state.sourceRecord = try makeRecord(turnID: XCTUnwrap(state.selectedTurnID))
        XCTAssertEqual(state.savedSources, .unavailable(.generating))
    }

    func testInterruptedAnswerCannotDisplayPreviousTurnsSources() throws {
        var state = QuickAssistRenderFixtures.state(
            isLoading: false, selectedResponse: "Previous answer", streamingDraft: nil,
            activeThreadID: "saved-thread"
        )
        state.sourceRecord = try makeRecord(turnID: XCTUnwrap(state.selectedTurnID))
        state.interruptedResponse = "Interrupted new answer"
        XCTAssertEqual(state.savedSources, .unavailable(.interrupted))
        state.interruptedResponse = nil
        XCTAssertEqual(try savedSnapshot(state.savedSources).turnID, state.selectedTurnID?.uuidString)
    }

    func testPreviousAnswerKeepsItsSourcesWhileFollowUpWaitsForText() throws {
        var state = QuickAssistRenderFixtures.state(
            isLoading: true, selectedResponse: "Previous answer", streamingDraft: nil,
            activeThreadID: "saved-thread"
        )
        state.sourceRecord = try makeRecord(turnID: XCTUnwrap(state.selectedTurnID))
        XCTAssertTrue(state.isUpdatingPreviousResult)
        XCTAssertEqual(try savedSnapshot(state.savedSources).turnID, state.selectedTurnID?.uuidString)
    }

    func testFirstRequestWithoutTextExplainsSourcesAreNotYetAvailable() {
        let state = QuickAssistRenderFixtures.state(isLoading: true, selectedResponse: nil, streamingDraft: nil)
        XCTAssertEqual(state.savedSources, .unavailable(.generating))
    }

    private func presentation(turnID: UUID?, record: QuickAssistCallRecord?) -> QuickAssistSourcePresentation {
        QuickAssistSourcePresentation(turnID: turnID, threadID: "saved-thread", record: record,
                                      isStreaming: false, isInterrupted: false)
    }

    private func savedSnapshot(_ presentation: QuickAssistSourcePresentation,
                               file: StaticString = #filePath, line: UInt = #line) throws -> QuickAssistSourceSnapshot {
        guard case .saved(let snapshot) = presentation else {
            XCTFail("Expected a saved source snapshot", file: file, line: line)
            throw SnapshotError.unavailable
        }
        return snapshot
    }

    private func makeRecord(turnID: UUID, threadID: String = "saved-thread",
                            questionSource: QuickAssistQuestionSource = .manual) -> QuickAssistCallRecord {
        QuickAssistCallRecord(
            sessionId: "saved-session", threadId: threadID, turnId: turnID.uuidString,
            provider: "Claude", model: "recorded-model", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            hasScreenshot: true, hasPreviousResponse: true, status: "success",
            transcriptText: "Recorded speech\nwith original spacing",
            question: "Which project supplied this answer?",
            extraContext: "Workspace: Original project\nRecorded knowledge and notes", responseText: "Saved answer",
            previousResponse: "Original prior answer\nwith retained context", questionSource: questionSource,
            evidencePackManifest: "transcript_len=42\nscreenshot_count=1"
        )
    }

    private enum SnapshotError: Error { case unavailable }
}
