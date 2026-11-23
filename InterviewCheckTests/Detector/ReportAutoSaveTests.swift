import XCTest
@testable import InterviewCheck

@MainActor
final class ReportAutoSaveTests: XCTestCase {
    func testAFinishedInterviewIsSavedOnceAsAPDF() async throws {
        let path = NSTemporaryDirectory() + "autosave-\(UUID().uuidString).sqlite"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reports-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(at: folder)
        }
        let database = SessionDatabase(databasePath: path)
        let defaults = UserDefaults(suiteName: "autosave.\(UUID().uuidString)")!
        let controller = InterviewController(timeline: InterviewTimeline(), database: database, settings: DetectorSettings(defaults: defaults))
        controller.startAudio = {}
        controller.stopAudio = {}
        controller.finishTranscription = { $0() }
        controller.roleProvider = { nil }
        let autosave = ReportAutoSave(defaults: defaults, database: database)
        autosave.watch(controller)

        controller.consentConfirmed = true
        controller.candidateName = "Jane: Doe/QA"
        controller.start()
        controller.end()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty ?? true, "off until a folder is chosen")

        autosave.folder = folder
        let first = autosave.save(id: controller.interview!.id)
        let again = autosave.save(id: controller.interview!.id)
        let file = try XCTUnwrap(first)
        XCTAssertNil(again, "each report once")
        XCTAssertTrue(file.lastPathComponent.hasSuffix(" Jane- Doe-QA.pdf"), file.lastPathComponent)
        let data = try Data(contentsOf: file)
        XCTAssertEqual(data.prefix(4), Data("%PDF".utf8))
        controller.stopTicking()
    }

    func testTheNextInterviewIsSavedWhenItEnds() async throws {
        let path = NSTemporaryDirectory() + "autosave-\(UUID().uuidString).sqlite"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reports-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(at: folder)
        }
        let database = SessionDatabase(databasePath: path)
        let defaults = UserDefaults(suiteName: "autosave.\(UUID().uuidString)")!
        let controller = InterviewController(timeline: InterviewTimeline(), database: database, settings: DetectorSettings(defaults: defaults))
        controller.startAudio = {}
        controller.stopAudio = {}
        controller.finishTranscription = { $0() }
        controller.roleProvider = { nil }
        let autosave = ReportAutoSave(defaults: defaults, database: database)
        autosave.folder = folder
        autosave.watch(controller)
        controller.consentConfirmed = true
        controller.candidateName = "Max Roe"
        controller.start()
        controller.end()
        let deadline = Date().addingTimeInterval(3)
        var files: [String] = []
        while files.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        }
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files.first?.contains("Max Roe") == true)
        controller.stopTicking()
    }

    func testChangedScoresRewriteTheSameFileAndFailuresAreRetried() throws {
        let path = NSTemporaryDirectory() + "autosave-\(UUID().uuidString).sqlite"
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("reports-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(at: base)
        }
        let database = SessionDatabase(databasePath: path)
        let defaults = UserDefaults(suiteName: "autosave.\(UUID().uuidString)")!
        let autosave = ReportAutoSave(defaults: defaults, database: database)
        var record = InterviewRecord(id: "i1", workspaceID: nil, roleTitle: "Backend Engineer", candidateName: "Ana Pop",
                                     consentConfirmedAt: Date(), startedAt: Date())
        let report = InterviewReportData(interview: record, questions: [], references: [:], scores: [:])

        // A folder that cannot be written (a file is in the way): not remembered, so tried again.
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let blocked = base.appendingPathComponent("blocked")
        try Data("x".utf8).write(to: blocked)
        autosave.folder = blocked
        XCTAssertNil(autosave.save(report))
        autosave.folder = base.appendingPathComponent("reports")
        let first = try XCTUnwrap(autosave.save(report), "the failed save is tried again")

        XCTAssertNil(autosave.save(report), "unchanged: not written twice")
        record.overallPercent = 64
        let changed = InterviewReportData(interview: record, questions: [], references: [:], scores: [:])
        let rewritten = try XCTUnwrap(autosave.save(changed), "changed scores: written again")
        XCTAssertEqual(rewritten, first, "in place, not a second file")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: first.deletingLastPathComponent().path).count, 1)
    }

    func testSavedAfterSlowAIAnswersEvenIfANewInterviewWasStarted() async throws {
        let path = NSTemporaryDirectory() + "autosave-\(UUID().uuidString).sqlite"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reports-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(at: folder)
        }
        let database = SessionDatabase(databasePath: path)
        let defaults = UserDefaults(suiteName: "autosave.\(UUID().uuidString)")!
        let controller = InterviewController(timeline: InterviewTimeline(), database: database, settings: DetectorSettings(defaults: defaults))
        controller.startAudio = {}
        controller.stopAudio = {}
        controller.finishTranscription = { $0() }
        controller.roleProvider = { nil }
        let autosave = ReportAutoSave(defaults: defaults, database: database)
        autosave.folder = folder
        autosave.watch(controller)
        controller.consentConfirmed = true
        controller.candidateName = "Slow Answers"
        controller.start()
        controller.referencesInFlight = ["q1"]          // an AI answer still coming after scoring gave up
        controller.end()
        controller.reset()                              // New Interview
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty, "not before the answers are in")
        controller.referencesInFlight = []
        var files: [String] = []
        let deadline = Date().addingTimeInterval(3)
        while files.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        }
        XCTAssertEqual(files.count, 1)
        controller.stopTicking()
    }
}
