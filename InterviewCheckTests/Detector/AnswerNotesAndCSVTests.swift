import XCTest
import InterviewCheckKit
@testable import InterviewCheck

final class AnswerNotesAndCSVTests: XCTestCase {
    private func makeDatabase() -> (SessionDatabase, String) {
        let path = NSTemporaryDirectory() + "notes-\(UUID().uuidString).sqlite"
        let database = SessionDatabase(databasePath: path)
        database.saveInterview(InterviewRecord(id: "i1", workspaceID: nil, roleTitle: "Backend, Payments",
                                               candidateName: "Sam \"Sammy\" Lee", consentConfirmedAt: Date(),
                                               startedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        database.saveInterviewQuestion(InterviewQuestionRecord(id: "q1", interviewID: "i1", ordinal: 1,
                                                               text: "=HYPERLINK(\"x\")", source: .live, markedAt: 0,
                                                               answerText: "A token bucket"))
        return (database, path)
    }

    func testNotesRoundTripClearAndGoWithTheInterview() {
        let (database, path) = makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: path) }

        database.saveAnswerNote("  Asked about Redis; vague.\nFollow up.  ", questionID: "q1")
        XCTAssertEqual(database.loadAnswerNote(questionID: "q1"), "Asked about Redis; vague.\nFollow up.")
        XCTAssertEqual(database.loadInterviewReport(id: "i1")?.notes, ["q1": "Asked about Redis; vague.\nFollow up."])

        database.saveAnswerNote("   ", questionID: "q1")
        XCTAssertEqual(database.loadAnswerNote(questionID: "q1"), "")

        database.saveAnswerNote("keep", questionID: "q1")
        database.saveAnswerLabel(.aiAssisted, questionID: "q1")
        let report = database.loadInterviewReport(id: "i1")
        XCTAssertEqual(report?.verdicts, ["q1": .aiAssisted])
        let markdown = InterviewReportComposer.markdown(report!)
        XCTAssertTrue(markdown.contains("Your verdict: **AI-assisted**"))
        XCTAssertTrue(markdown.contains("> keep"))

        database.deleteInterview(id: "i1")
        XCTAssertEqual(database.loadAnswerNote(questionID: "q1"), "")
    }

    func testCSVQuotesTextAndDefusesFormulas() throws {
        let (database, path) = makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: path) }
        database.saveAnswerNote("line one\nline two, with comma", questionID: "q1")
        let report = try XCTUnwrap(database.loadInterviewReport(id: "i1"))

        let csv = InterviewCSV.make([report])
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines.first, InterviewCSV.header.joined(separator: ","))
        XCTAssertTrue(csv.contains("\"Sam \"\"Sammy\"\" Lee\""))
        XCTAssertTrue(csv.contains("\"Backend, Payments\""))
        XCTAssertTrue(csv.contains("\"'=HYPERLINK(\"\"x\"\")\""), "a formula is kept as text")
        XCTAssertTrue(csv.contains("\"line one\nline two, with comma\""))
        XCTAssertTrue(csv.contains("Not scored"))
        XCTAssertTrue(csv.hasSuffix("\r\n"))

        XCTAssertEqual(InterviewCSV.text("plain"), "plain")
        XCTAssertEqual(InterviewCSV.text("-5 points"), "\"'-5 points\"")
    }
}
