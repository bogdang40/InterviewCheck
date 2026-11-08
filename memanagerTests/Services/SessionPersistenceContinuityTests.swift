import AppKit
import XCTest
@testable import memanager

@MainActor
final class SessionPersistenceContinuityTests: XCTestCase {
    private var directory: URL!
    private var database: SessionDatabase!
    private var logger: SessionLogger!
    private var audio: AudioCaptureService!
    private var resumeService: SessionResumeService!
    private var controller: SessionController!
    private var starts: StartRecorder!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard TestRuntime.isRunningUnitTests else { throw XCTSkip("Requires isolated XCTest storage") }
        directory = TestRuntime.temporaryDirectory.appendingPathComponent("continuity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = SessionDatabase(databasePath: directory.appendingPathComponent("sessions.sqlite").path)
        logger = SessionLogger(database: database)
        audio = AudioCaptureService(transcriptLogger: logger)
        let audioSessionID = UUID()
        audio.sessionIdentityProvider = { audioSessionID }
        let writer = SessionModeSnapshotWriter(
            database: database, modeProvider: { nil },
            attachmentStorage: FileSystemModeAttachmentStorage.shared,
            snapshotAssetStorage: SessionModeSnapshotAssetStorage()
        )
        resumeService = SessionResumeService(snapshotWriter: writer, database: database, logger: logger)
        let starts = StartRecorder()
        self.starts = starts
        controller = SessionController(
            workstreamTimelineRepository: WorkstreamTimelineRepository(logger: logger),
            relatedMemoryService: RelatedMemoryService(logger: logger),
            logger: logger, audioService: audio, sessionResumeService: resumeService,
            startAudioCapture: { starts.reasons.append($0); starts.onStart?() }
        )
    }

    override func tearDown() async throws {
        controller?.stopRuntimeServices()
        weak var remainingController = controller
        weak var remainingAudio = audio
        weak var remainingLogger = logger
        controller = nil
        audio = nil
        resumeService = nil
        logger = nil
        starts = nil
        let deadline = Date().addingTimeInterval(3)
        while (remainingController != nil || remainingAudio != nil || remainingLogger != nil), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard remainingController == nil, remainingAudio == nil, remainingLogger == nil else {
            database = nil
            XCTFail("Continuity fixture still owns its database; preserving temporary files")
            return
        }
        database?.flush()
        weak var remainingDatabase = database
        database = nil
        guard remainingDatabase == nil else {
            XCTFail("Database is still retained; preserving temporary files")
            return
        }
        if let directory { try FileManager.default.removeItem(at: directory) }
        directory = nil
        try await super.tearDown()
    }

    func testPauseAndCancelledAnswerPersistSettledMetadata() throws {
        var session = Session()
        logger.logSessionStarted(session: session, provider: "fixture", model: "fixture-model")
        session.transcript = "Me: complete\ncaptured words"
        session.screenshots = [Screenshot(image: NSImage(size: NSSize(width: 2, height: 2)), capturedAt: Date())]
        controller.session = session
        controller.syncSessionStateForTesting(with: .paused)
        let paused = try XCTUnwrap(database.getSessionRecord(id: session.id.uuidString))
        XCTAssertEqual(paused.state, "paused")
        XCTAssertEqual(paused.transcript, session.transcript)
        XCTAssertEqual(paused.transcriptWordCount, 4)
        XCTAssertEqual(paused.screenshotCount, 1)
        XCTAssertFalse(paused.hasResponse)

        controller.isStreaming = true
        controller.updateSessionResponse(MentorResponse.parse(from: "## Problem\nRetained partial answer"))
        XCTAssertFalse(try XCTUnwrap(database.getSessionRecord(id: session.id.uuidString)).hasResponse,
                       "Per-chunk response updates must not write snapshots")
        controller.cancelActiveRequest()
        XCTAssertTrue(try XCTUnwrap(database.getSessionRecord(id: session.id.uuidString)).hasResponse)
    }

    func testLegacyResumeReconstructsOnlyRecordedTranscriptSegments() throws {
        let id = UUID()
        database.insertSession(SessionRecord(id: id.uuidString, startedAt: Date(), state: "idle", transcript: " \n"))
        logger.logTranscriptEntry(sessionId: id.uuidString, speaker: "Me", text: "First saved segment")
        logger.logTranscriptEntry(sessionId: id.uuidString, speaker: "Speaker 1", text: "Second saved segment")
        let payload = try XCTUnwrap(resumeService.resumePayload(sessionID: id))
        XCTAssertEqual(payload.transcript, "Me: First saved segment\nSpeaker 1: Second saved segment")
        XCTAssertEqual(payload.transcriptEntries.map(\.text), ["First saved segment", "Second saved segment"])
    }

    func testResumeThenStartPreservesIdentityTextAndHistoricalMetadata() async throws {
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 1100)
        let complete = "Me: complete text including material absent from legacy rows"
        database.insertSession(SessionRecord(
            id: id.uuidString, startedAt: start, endedAt: end, state: "idle",
            transcript: complete, transcriptWordCount: 10, screenshotCount: 2,
            hasResponse: true, provider: "fixture", model: "fixture-model"
        ))
        logger.logTranscriptEntry(sessionId: id.uuidString, speaker: "Me", text: "incomplete old row")
        await controller.resumeSessionForTesting(sessionID: id)
        await controller.startSessionForTesting()
        XCTAssertEqual(starts.reasons, [.restoredSession])
        XCTAssertEqual(controller.session.id, id)
        XCTAssertEqual(controller.session.transcript, complete)
        XCTAssertEqual(audio.transcript, complete)
        XCTAssertEqual(audio.captureState, .idle, "The injected start must never activate hardware")
        XCTAssertNil(controller.session.response, "Historical flags do not reconstruct response content")
        controller.cancelActiveRequest()
        let saved = try XCTUnwrap(database.getSessionRecord(id: id.uuidString))
        XCTAssertEqual(saved.startedAt, start)
        XCTAssertEqual(saved.endedAt, end)
        XCTAssertEqual(saved.transcript, complete)
        XCTAssertEqual(saved.screenshotCount, 2)
        XCTAssertTrue(saved.hasResponse)
        XCTAssertEqual(database.getRecentSessions().map(\.id), [id.uuidString])
    }

    func testSameSpeakerSegmentsAreAllPersistedWhileDisplayStaysMerged() {
        let id = UUID()
        database.insertSession(SessionRecord(id: id.uuidString, startedAt: Date(), state: "idle"))
        audio.sessionIdentityProvider = { id }
        audio.appendTranscriptEntry("First accepted segment", speaker: .me)
        audio.appendTranscriptEntry("Second accepted segment", speaker: .me)
        audio.appendTranscriptEntry(" \n", speaker: .me)
        XCTAssertEqual(audio.transcriptEntries.map(\.text), ["First accepted segment Second accepted segment"])
        XCTAssertEqual(logger.getTranscriptEntries(sessionId: id.uuidString).map(\.text),
                       ["First accepted segment", "Second accepted segment"])
    }

    func testRestoredOverlayResumeUsesContinuationStart() async {
        let id = UUID()
        database.insertSession(SessionRecord(id: id.uuidString, startedAt: Date(), state: "idle", transcript: "saved context"))
        await controller.resumeSessionForTesting(sessionID: id)
        let requested = expectation(description: "overlay requested restored capture")
        starts.onStart = { requested.fulfill() }
        controller.togglePauseSession()
        await fulfillment(of: [requested], timeout: 1)
        XCTAssertEqual(starts.reasons, [.restoredSession])
        XCTAssertEqual(controller.session.id, id)
        XCTAssertEqual(audio.transcript, "saved context")
        XCTAssertEqual(audio.captureState, .idle)
    }

    func testRestoredTextSurvivesAppendConsolidationAndMergedStreamReplacement() {
        let old = TranscriptEntry(speaker: .me, text: "legacy row")
        let complete = "Me: complete saved text beyond the legacy row"
        XCTAssertTrue(audio.restoreTranscriptForResume(complete, entries: [old]))
        audio.appendTranscriptEntry("new words", speaker: .me)
        audio.consolidateTranscriptEntries()
        audio.rebuildTranscript()
        XCTAssertEqual(audio.transcript, complete + "\nMe: new words")
        XCTAssertEqual(audio.transcriptEntries.first?.id, old.id)

        audio.replaceLiveTranscriptEntries([TranscriptEntry(speaker: .speaker(0), text: "new merged stream")])
        audio.rebuildTranscript()
        XCTAssertEqual(audio.transcript, complete + "\nSpeaker 1: new merged stream")
        XCTAssertEqual(audio.transcriptEntries.count, 2)
    }

    func testRestoreRejectsNonIdleIntentAndStartRequiresRestoredContext() {
        audio.transcript = "keep current text"
        audio.desiredState = .recording
        XCTAssertFalse(audio.restoreTranscriptForResume("replacement", entries: []))
        XCTAssertEqual(audio.transcript, "keep current text")
        audio.desiredState = .idle
        let reason = AudioCaptureService.StartReason.restoredSession
        XCTAssertTrue(reason.canStart(from: .idle, hasRestoredTranscript: true))
        XCTAssertFalse(reason.canStart(from: .idle, hasRestoredTranscript: false))
        XCTAssertFalse(reason.canStart(from: .recording, hasRestoredTranscript: true))
        XCTAssertFalse(reason.canStart(from: .paused, hasRestoredTranscript: true))
    }

    func testReplacementSavesSettledAudioBeforeClearingPriorSession() async throws {
        var previous = Session()
        previous.startedAt = Date(timeIntervalSince1970: 1000)
        previous.transcript = "stale controller text"
        controller.session = previous
        logger.logSessionStarted(session: previous, provider: "fixture", model: "fixture-model")
        let target = UUID()
        database.insertSession(SessionRecord(id: target.uuidString, startedAt: Date(), state: "idle", transcript: "restore target"))
        audio.transcript = "final complete audio text"
        audio.transcriptEntries = [TranscriptEntry(speaker: .me, text: "final complete audio text")]

        await controller.resumeSessionForTesting(sessionID: target)

        let saved = try XCTUnwrap(database.getSessionRecord(id: previous.id.uuidString))
        XCTAssertEqual(saved.transcript, "final complete audio text")
        XCTAssertNotNil(saved.endedAt)
        XCTAssertEqual(controller.session.id, target)
        XCTAssertEqual(audio.transcript, "restore target")
    }

    func testStartingNewSessionDoesNotOverwriteEndedRecordWithClearedAudio() async throws {
        var previous = Session()
        previous.startedAt = Date(timeIntervalSince1970: 1000)
        previous.transcript = "saved ended session text"
        controller.session = previous
        logger.logSessionStarted(session: previous, provider: "fixture", model: "fixture-model")
        logger.logSessionEnded(sessionId: previous.id)
        let originalEnd = database.getSessionRecord(id: previous.id.uuidString)?.endedAt
        audio.transcript = ""
        controller.session.transcript = ""

        await controller.startSessionForTesting()

        XCTAssertEqual(starts.reasons, [.newSession])
        XCTAssertNotEqual(controller.session.id, previous.id)
        XCTAssertEqual(database.getSessionRecord(id: previous.id.uuidString)?.transcript, "saved ended session text")
        XCTAssertEqual(database.getSessionRecord(id: previous.id.uuidString)?.endedAt, originalEnd)
    }

    func testMissingResumeTargetPreservesCurrentTranscriptAndLogger() async {
        var current = Session()
        current.transcript = "current session must survive"
        controller.session = current
        audio.transcript = current.transcript
        logger.logSessionStarted(session: current, provider: "fixture", model: "fixture-model")

        await controller.resumeSessionForTesting(sessionID: UUID())

        XCTAssertEqual(controller.session.id, current.id)
        XCTAssertEqual(controller.session.transcript, current.transcript)
        XCTAssertEqual(audio.transcript, current.transcript)
        XCTAssertTrue(logger.isLoggingSession(current.id))
        XCTAssertEqual(database.getSessionRecord(id: current.id.uuidString)?.transcript, current.transcript)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertTrue(starts.reasons.isEmpty)
    }

    func testQueuedOldMergerCannotReplaceRestoredTranscript() async {
        let oldMerger = TranscriptMerger()
        oldMerger.appendMicTranscript(
            DeepgramTranscriptSegment(text: "old stream words", speaker: nil, startTime: 0, endTime: 1,
                                      isFinal: true, confidence: 1, words: []),
            streamStart: Date(), receivedAt: Date()
        )
        let published = expectation(description: "old merger published")
        DispatchQueue.main.async { published.fulfill() }
        await fulfillment(of: [published], timeout: 1)
        XCTAssertEqual(oldMerger.mergedEntries.count, 1)
        audio.transcriptMerger = oldMerger
        audio.syncMergedEntries()
        XCTAssertTrue(audio.restoreTranscriptForResume("restored complete text", entries: []))
        let drained = expectation(description: "old queued sync drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
        XCTAssertEqual(audio.transcript, "restored complete text")
        XCTAssertTrue(audio.transcriptEntries.isEmpty)
    }
}

private final class StartRecorder {
    var reasons: [AudioCaptureService.StartReason] = []
    var onStart: (() -> Void)?
}
