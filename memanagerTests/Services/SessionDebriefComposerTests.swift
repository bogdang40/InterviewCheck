import XCTest
@testable import memanager

final class SessionDebriefComposerTests: XCTestCase {
    func testComposerBuildsThreeDrillsWhenEvidenceExists() async {
        let composer = TemplateSessionDebriefComposer()
        let transcriptEntries = [
            TranscriptEntryRecord(sessionId: "session", speaker: "me", text: String(repeating: "word ", count: 160))
        ]
        let calls = [
            QuickAssistCallRecord(
                sessionId: "session",
                threadId: "thread",
                turnId: "turn-1",
                provider: "Claude",
                model: "haiku",
                transcriptText: "Speaker 1: Explain the tradeoff",
                question: "Explain the tradeoff",
                verificationStatus: .verified,
                unsupportedClaimCount: 0
            ),
            QuickAssistCallRecord(
                sessionId: "session",
                threadId: "thread",
                turnId: "turn-2",
                provider: "Claude",
                model: "haiku",
                transcriptText: "Speaker 1: That answer is not enough",
                question: "Recover from pushback",
                verificationStatus: .failed,
                unsupportedClaimCount: 2,
                verificationSuggestedFollowUp: "Recover from the criticism with a tighter answer."
            )
        ]

        let debrief = await composer.compose(
            sessionId: "session",
            transcriptEntries: transcriptEntries,
            quickAssistCalls: calls,
            coachFindings: [],
            responseCardEvents: [],
            existingDebriefId: nil
        )

        XCTAssertNotNil(debrief)
        XCTAssertEqual(debrief?.drills.count, 3)
        let templateDrillKinds: Set<SessionDrillKind> = [.clarification, .tradeoff, .recovery]
        XCTAssertEqual(Set(debrief?.drills.map { $0.kind } ?? []), templateDrillKinds)
    }

    func testComposerReturnsNilForInsufficientEvidence() async {
        let composer = TemplateSessionDebriefComposer()
        let debrief = await composer.compose(
            sessionId: "session",
            transcriptEntries: [TranscriptEntryRecord(sessionId: "session", speaker: "me", text: "short")],
            quickAssistCalls: [],
            coachFindings: [],
            responseCardEvents: [],
            existingDebriefId: nil
        )

        XCTAssertNil(debrief)
    }

    func testSummaryComposerPublishesGeneratingAndCompletedNotifications() async {
        let sessionID = UUID()
        let database = SessionDatabase(databasePath: ":memory:")
        database.insertSession(SessionRecord(
            id: sessionID.uuidString, startedAt: Date(), state: "idle",
            transcript: "We agreed to send a recap with the decisions."
        ))
        let composer = SessionSummaryComposer(
            database: database,
            snapshotWriter: SessionModeSnapshotWriter(
                database: database,
                modeProvider: { nil },
                attachmentStorage: FileSystemModeAttachmentStorage.shared,
                snapshotAssetStorage: SessionModeSnapshotAssetStorage.shared
            ),
            llmClient: SummaryLLMClientStub(
                response: """
                {
                  "actionItems": [
                    {
                      "title": "Send recap",
                      "owner": "Me",
                      "dueDate": "Tomorrow",
                      "notes": "Include the decisions"
                    }
                  ],
                  "backgroundSummary": "The session covered resume flow and frozen mode behavior.",
                  "followUpEmail": "Following up with the agreed summary."
                }
                """
            ),
            settings: .shared
        )

        var statuses: [String] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .sessionSummaryDidChange,
            object: nil,
            queue: nil
        ) { notification in
            guard
                let observedSessionID = notification.userInfo?[SessionSummaryNotificationUserInfo.sessionID] as? String,
                observedSessionID == sessionID.uuidString,
                let status = notification.userInfo?[SessionSummaryNotificationUserInfo.status] as? String
            else {
                return
            }
            statuses.append(status)
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        await composer.generate(sessionID: sessionID)

        let summary = composer.loadCached(sessionID: sessionID)
        XCTAssertEqual(
            statuses,
            [SessionSummary.Status.generating.rawValue, SessionSummary.Status.completed.rawValue]
        )
        XCTAssertEqual(summary?.status, .completed)
        XCTAssertEqual(summary?.actionItems.first?.title, "Send recap")
    }

    func testMissingParentSkipsGenerationAndNotifications() async {
        let sessionID = UUID()
        let database = SessionDatabase(databasePath: ":memory:")
        let client = SummaryLLMClientStub(response: "{\"actionItems\": [], \"backgroundSummary\": \"Unexpected summary\"}")
        let composer = SessionSummaryComposer(
            database: database,
            snapshotWriter: SessionModeSnapshotWriter(
                database: database,
                modeProvider: { nil },
                attachmentStorage: FileSystemModeAttachmentStorage.shared,
                snapshotAssetStorage: SessionModeSnapshotAssetStorage.shared
            ),
            llmClient: client,
            settings: .shared
        )
        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .sessionSummaryDidChange, object: nil, queue: nil
        ) { notification in
            if notification.userInfo?[SessionSummaryNotificationUserInfo.sessionID] as? String == sessionID.uuidString {
                notificationCount += 1
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await composer.generate(sessionID: sessionID)

        XCTAssertEqual(client.callCount, 0)
        XCTAssertEqual(notificationCount, 0)
        XCTAssertNil(composer.loadCached(sessionID: sessionID))
        XCTAssertTrue(database.getRecentSessions().isEmpty)
    }
}

private final class SummaryLLMClientStub: SessionSummaryLLMCalling {
    let response: String
    private(set) var callCount = 0

    init(response: String) {
        self.response = response
    }

    func send(systemPrompt: String, userPrompt: String, settings: SettingsManager) async throws -> String {
        callCount += 1
        return response
    }
}
