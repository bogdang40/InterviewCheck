import XCTest
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

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("Timed out"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
