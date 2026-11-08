import XCTest
import InterviewCheckConnectors
import InterviewCheckKit
@testable import InterviewCheck

@MainActor
final class RecordingAnalyzerTests: XCTestCase {
    private func word(_ text: String, _ start: Double, speaker: Int) -> DeepgramWord {
        DeepgramWord(word: text.lowercased().trimmingCharacters(in: .punctuationCharacters), start: start,
                     end: start + 0.3, confidence: 0.9, speaker: speaker, punctuatedWord: text)
    }

    private func sentence(_ text: String, from start: Double, speaker: Int) -> [DeepgramWord] {
        text.split(separator: " ").enumerated().map { word(String($1), start + Double($0) * 0.4, speaker: speaker) }
    }

    func testParsesDeepgramPrerecordedReply() throws {
        let json = #"{"results":{"channels":[{"alternatives":[{"transcript":"hi there","words":[{"word":"hi","start":0.1,"end":0.3,"confidence":0.9,"speaker":1,"punctuated_word":"Hi"}]}]}]}}"#
        let words = try RecordingTranscriber.words(from: Data(json.utf8))
        XCTAssertEqual(words.first?.speaker, 1)
        XCTAssertEqual(words.first?.punctuatedWord, "Hi")
        XCTAssertTrue(RecordingTranscriber.endpoint.absoluteString.contains("filler_words=true"))
        XCTAssertTrue(RecordingTranscriber.endpoint.absoluteString.contains("diarize=true"))
    }

    func testRecordingBecomesAScoredReport() async throws {
        let path = NSTemporaryDirectory() + "recording-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = SessionDatabase(databasePath: path)
        let settings = DetectorSettings(defaults: UserDefaults(suiteName: "rec.\(UUID().uuidString)")!)
        settings.judgeEnabled = false
        settings.useEmbeddings = false

        let words = sentence("Tell me about a hard bug you fixed recently.", from: 0, speaker: 0)
            + sentence("Sure, we had a race condition in the billing service where two workers charged the same invoice twice", from: 5, speaker: 1)
            + sentence("How did you find it?", from: 15, speaker: 0)
            + sentence("I added tracing around the charge path and saw two workers pick up the same message after a timeout", from: 18, speaker: 1)

        let analyzer = RecordingAnalyzer()
        analyzer.database = database
        analyzer.settings = settings
        analyzer.transcribe = { _ in words }
        analyzer.start(file: URL(fileURLWithPath: "/tmp/interview.wav"), candidateName: "Ana Diaz", role: nil)
        try await waitUntil { analyzer.step == .chooseSpeaker }
        XCTAssertEqual(analyzer.speakers.map(\.id), [0, 1])
        XCTAssertEqual(analyzer.candidateSpeaker, 1, "the voice with the most words is preselected")

        analyzer.analyze()
        try await waitUntil { if case .finished = analyzer.step { return true } else { return false } }
        guard case .finished(let id, let questions) = analyzer.step else { return XCTFail("not finished") }
        XCTAssertEqual(questions, 2)

        let report = try XCTUnwrap(database.loadInterviewReport(id: id))
        XCTAssertEqual(report.interview.candidateName, "Ana Diaz")
        XCTAssertEqual(report.questions.map(\.text), ["Tell me about a hard bug you fixed recently.", "How did you find it?"])
        XCTAssertEqual(report.scores.count, 2)
        XCTAssertNotNil(report.interview.overallPercent)
        XCTAssertEqual(database.loadInterviewWords(interviewID: id).count, words.count)
    }

    func testMeetingTranscriptIsScoredByNameWithLowConfidence() async throws {
        let path = NSTemporaryDirectory() + "transcript-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = SessionDatabase(databasePath: path)
        let settings = DetectorSettings(defaults: UserDefaults(suiteName: "vtt.\(UUID().uuidString)")!)
        settings.judgeEnabled = false
        settings.useEmbeddings = false
        database.addExternalRecordings([ExternalRecordingFixture.zoom])

        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:04.000
        <v Sam Lead>Tell me about a hard bug you fixed recently.</v>

        00:00:09.500 --> 00:00:16.000
        <v Ana Diaz>Sure, we had a race condition in the billing service where two workers charged the same invoice.</v>

        00:00:18.000 --> 00:00:20.000
        <v Sam Lead>How did you find it?</v>

        00:00:21.000 --> 00:00:27.000
        <v Ana Diaz>I added tracing around the charge path and saw two workers pick up the same message.</v>
        """
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("meeting.vtt")
        try vtt.write(to: file, atomically: true, encoding: .utf8)

        let analyzer = RecordingAnalyzer()
        analyzer.database = database
        analyzer.settings = settings
        analyzer.meetingStart = Date(timeIntervalSince1970: 1_794_000_000)
        analyzer.startTranscript(file: file, candidateName: "Ana Diaz", role: nil,
                                 recordingID: ExternalRecordingFixture.zoom.id, cleanup: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "the download folder is removed")
        XCTAssertEqual(analyzer.step, .chooseSpeaker)
        XCTAssertEqual(analyzer.speakers.map(\.name), ["Sam Lead", "Ana Diaz"])
        XCTAssertEqual(analyzer.candidateSpeaker, 1, "the candidate is picked by name")

        analyzer.analyze()
        try await waitUntil { if case .finished = analyzer.step { return true } else { return false } }
        guard case .finished(let id, let questions) = analyzer.step else { return XCTFail("not finished") }
        XCTAssertEqual(questions, 2)
        let report = try XCTUnwrap(database.loadInterviewReport(id: id))
        XCTAssertEqual(report.interview.scoredFrom, .transcript)
        XCTAssertEqual(report.interview.startedAt, Date(timeIntervalSince1970: 1_794_000_000))
        XCTAssertTrue(report.scores.values.allSatisfy { $0.confidence == .low })
        XCTAssertEqual(database.loadExternalRecordings().first?.interviewID, id)
        XCTAssertTrue(InterviewReportComposer.markdown(report).contains("meeting's own transcript"))
    }

    func testCandidateVoiceMatchesWholeNamesOnly() {
        let speakers = [RecordingAnalyzer.SpeakerSample(id: 0, wordCount: 40, sample: "", name: "Brian Lee"),
                        RecordingAnalyzer.SpeakerSample(id: 1, wordCount: 90, sample: "", name: "Ian Ruiz")]
        XCTAssertEqual(RecordingAnalyzer.speaker(named: "Ian", in: speakers), 1, "Ian is not Brian")
        XCTAssertEqual(RecordingAnalyzer.speaker(named: "ian ruiz", in: speakers), 1)
        XCTAssertNil(RecordingAnalyzer.speaker(named: "Lee Park", in: speakers), "every part of the name must match")
        let twins = speakers + [RecordingAnalyzer.SpeakerSample(id: 2, wordCount: 5, sample: "", name: "Ian Smith")]
        XCTAssertNil(RecordingAnalyzer.speaker(named: "Ian", in: twins), "two speakers named Ian: no guess")
    }

    func testTranscriptWithoutSpeakersIsRefused() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).vtt")
        defer { try? FileManager.default.removeItem(at: file) }
        try "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nHello there.\n".write(to: file, atomically: true, encoding: .utf8)
        let analyzer = RecordingAnalyzer()
        analyzer.startTranscript(file: file, candidateName: "", role: nil)
        guard case .failed(let message) = analyzer.step else { return XCTFail("should fail") }
        XCTAssertTrue(message.contains("no speaker names"))
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("Timed out"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

enum ExternalRecordingFixture {
    static let zoom = ExternalRecording(source: .zoom, externalID: "BOKX==", title: "Interview: Ana Diaz",
                                        startedAt: Date(timeIntervalSince1970: 1_794_000_000), duration: 1800,
                                        files: [ExternalFile(kind: .transcript, filename: "a.vtt",
                                                             url: URL(string: "https://zoom.us/rec/t")!, needsAuth: true)])
}
