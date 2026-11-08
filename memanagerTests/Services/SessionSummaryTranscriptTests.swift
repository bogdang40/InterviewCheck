import XCTest
@testable import memanager

final class SessionSummaryTranscriptTests: XCTestCase {
    private var directory: URL!
    private var database: SessionDatabase!
    private var composer: SessionSummaryComposer!
    private var client: TranscriptSummaryClient!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard TestRuntime.isRunningUnitTests else {
            throw XCTSkip("Summary fixtures require isolated XCTest defaults")
        }
        directory = TestRuntime.temporaryDirectory
            .appendingPathComponent("summary-\(UUID().uuidString)", isDirectory: true)
        database = SessionDatabase(databasePath: directory.appendingPathComponent("sessions.sqlite").path)
        client = TranscriptSummaryClient()
        composer = SessionSummaryComposer(
            database: database,
            snapshotWriter: SessionModeSnapshotWriter(
                database: database,
                modeProvider: { nil },
                attachmentStorage: FileSystemModeAttachmentStorage(),
                snapshotAssetStorage: SessionModeSnapshotAssetStorage()
            ),
            llmClient: client,
            settings: .shared
        )
    }

    override func tearDownWithError() throws {
        composer = nil
        client = nil
        database?.flush()
        weak var remainingDatabase = database
        database = nil
        defer { directory = nil }
        guard remainingDatabase == nil else {
            XCTFail("Summary database is still retained; keeping temporary files")
            try super.tearDownWithError()
            return
        }
        if let directory { try FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    func testSavedTranscriptSuppliesMissingAndIncompleteEntries() async throws {
        let savedText = "Use request keys for retries.\nStore the original result until the retry window closes."
        for childRows in [[], ["Use request keys for retries."]] {
            let sessionID = insertSession(transcript: "  \(savedText)\n", entries: childRows)
            await composer.generate(sessionID: sessionID)

            XCTAssertTrue(client.userPrompt.contains("Transcript:\n\(savedText)\n\nProduce"))
            XCTAssertFalse(client.userPrompt.contains("Fixture speaker:"))
            XCTAssertFalse(client.userPrompt.contains("no transcript captured"))
            XCTAssertEqual(composer.loadCached(sessionID: sessionID)?.status, .completed)
        }
    }

    func testMissingOrBlankSavedTranscriptUsesInjectedEntries() async {
        for savedText: String? in [nil, "", " \n\t "] {
            let sessionID = insertSession(transcript: savedText, entries: ["Use the injected child row."])
            await composer.generate(sessionID: sessionID)

            XCTAssertTrue(client.userPrompt.contains("Transcript:\nFixture speaker: Use the injected child row."))
            XCTAssertFalse(client.userPrompt.contains("no transcript captured"))
            XCTAssertEqual(composer.loadCached(sessionID: sessionID)?.status, .completed)
        }
    }

    func testProviderFailureFallbackUsesSavedTranscript() async throws {
        client.shouldFail = true
        let savedText = "The complete\ntranscript has seven saved words."
        let sessionID = insertSession(transcript: savedText, entries: ["Incomplete child text."])
        await composer.generate(sessionID: sessionID)

        let summary = try XCTUnwrap(composer.loadCached(sessionID: sessionID))
        XCTAssertEqual(summary.status, .heuristic)
        XCTAssertEqual(summary.backgroundSummary, "Captured 7 words in the saved session transcript.\nTranscript excerpt: \(savedText)")
        XCTAssertTrue(summary.actionItems.isEmpty)
        XCTAssertNil(summary.followUpEmailDraft)
        XCTAssertEqual(summary.errorMessage, "Fixture provider failure")
    }

    func testMalformedResponseFallbackUsesSavedTranscript() async throws {
        client.response = "This is not JSON."
        let sessionID = insertSession(transcript: "The saved decision is to retry safely.", entries: [])
        await composer.generate(sessionID: sessionID)

        let summary = try XCTUnwrap(composer.loadCached(sessionID: sessionID))
        XCTAssertEqual(summary.status, .heuristic)
        XCTAssertTrue(summary.backgroundSummary.contains("The saved decision is to retry safely."))
        XCTAssertFalse(summary.backgroundSummary.contains("0 transcript entries"))
    }

    func testFallbackUsesInjectedEntriesWhenSavedTranscriptIsEmpty() async throws {
        client.shouldFail = true
        let sessionID = insertSession(transcript: "", entries: ["First saved entry.", "Last saved entry."])
        await composer.generate(sessionID: sessionID)

        let summary = try XCTUnwrap(composer.loadCached(sessionID: sessionID))
        XCTAssertEqual(summary.status, .heuristic)
        XCTAssertEqual(summary.backgroundSummary, "Captured 2 transcript entries (6 words).\nOpened with: First saved entry.\nClosed with: Last saved entry.")
    }

    func testEmptyTranscriptHasExplicitEmptyPromptAndFallback() async throws {
        client.shouldFail = true
        let sessionID = insertSession(transcript: nil, entries: [])
        await composer.generate(sessionID: sessionID)

        XCTAssertTrue(client.userPrompt.contains("Transcript:\n(no transcript captured)"))
        let summary = try XCTUnwrap(composer.loadCached(sessionID: sessionID))
        XCTAssertEqual(summary.backgroundSummary, "Captured 0 transcript entries (0 words).")
        XCTAssertTrue(summary.actionItems.isEmpty)
    }

    func testLongSavedTranscriptRetainsPromptLimitAndFullFallbackEvidence() async throws {
        client.shouldFail = true
        let ending = "Final decision from the saved transcript."
        let savedText = String(repeating: "word ", count: 9_000) + ending
        let sessionID = insertSession(transcript: savedText, entries: [])
        await composer.generate(sessionID: sessionID)

        XCTAssertTrue(client.userPrompt.contains(String(repeating: "word ", count: 8_000) + "\n[... transcript truncated ...]"))
        XCTAssertFalse(client.userPrompt.contains(ending))
        let summary = try XCTUnwrap(composer.loadCached(sessionID: sessionID))
        XCTAssertTrue(summary.backgroundSummary.contains("Captured 9006 words in the saved session transcript."))
        XCTAssertTrue(summary.backgroundSummary.hasSuffix(ending))
    }

    private func insertSession(transcript: String?, entries: [String]) -> UUID {
        let sessionID = UUID()
        database.insertSession(SessionRecord(
            id: sessionID.uuidString,
            startedAt: Date(timeIntervalSince1970: 1_000),
            state: "idle",
            transcript: transcript
        ))
        for (index, text) in entries.enumerated() {
            database.insertTranscriptEntry(TranscriptEntryRecord(
                sessionId: sessionID.uuidString,
                speaker: "Fixture speaker",
                text: text,
                timestamp: Date(timeIntervalSince1970: Double(1_000 + index))
            ))
        }
        database.flush()
        return sessionID
    }
}

private final class TranscriptSummaryClient: SessionSummaryLLMCalling {
    private(set) var userPrompt = ""
    var response = """
    {"actionItems": [], "backgroundSummary": "Fixture summary", "followUpEmail": null}
    """
    var shouldFail = false

    func send(systemPrompt: String, userPrompt: String, settings: SettingsManager) async throws -> String {
        self.userPrompt = userPrompt
        if shouldFail { throw Failure() }
        return response
    }

    private struct Failure: LocalizedError {
        var errorDescription: String? { "Fixture provider failure" }
    }
}
