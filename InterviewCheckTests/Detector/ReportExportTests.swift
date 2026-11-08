import PDFKit
import XCTest
import InterviewCheckKit
@testable import InterviewCheck

@MainActor
final class ReportExportTests: XCTestCase {
    private func report(questions: Int) -> InterviewReportData {
        let interview = InterviewRecord(id: "i1", workspaceID: nil, roleTitle: "Backend Engineer",
                                        candidateName: "Sam Lee", consentConfirmedAt: Date(), startedAt: Date(),
                                        endedAt: Date(), overallPercent: 72, flaggedCount: 2, questionCount: questions)
        let records = (1...questions).map { index in
            InterviewQuestionRecord(id: "q\(index)", interviewID: "i1", ordinal: index,
                                    text: "Question \(index): how would you design a rate limiter?",
                                    source: .live, markedAt: Double(index), answerText: String(repeating: "A long answer. ", count: 60))
        }
        return InterviewReportData(interview: interview, questions: records, references: [:], scores: [:])
    }

    func testPDFSpansSeveralLetterPages() throws {
        let data = try XCTUnwrap(PaginatedPDF.data(html: InterviewReportComposer.html(report(questions: 12))))
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(document.pageCount, 1)
        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 612, accuracy: 1)
        XCTAssertEqual(bounds.height, 792, accuracy: 1)
        XCTAssertTrue(document.string?.contains("Sam Lee") ?? false)
        if let directory = ProcessInfo.processInfo.environment["INTERVIEWCHECK_RENDER_DIR"] {
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("report.pdf"))
        }
    }

    func testMarkdownCarriesTheCaveatAndQuestions() {
        let markdown = InterviewReportComposer.markdown(report(questions: 2))
        XCTAssertTrue(markdown.hasPrefix("# Interview report: Sam Lee"))
        XCTAssertTrue(markdown.contains("not proof"))
        XCTAssertTrue(markdown.contains("## Q2."))
    }
}
