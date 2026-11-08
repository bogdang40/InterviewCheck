import AppKit
import XCTest
@testable import InterviewCheck

@MainActor
final class DocumentAndRoleFileTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("doctext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private let posting = "Senior Backend Engineer\n\nYou will own the payments API.\r\nGo, Postgres, Redis.   \n\n\n\nApply now."

    func testReadsWordRTFTextAndPDF() throws {
        let attributed = NSAttributedString(string: posting)
        let range = NSRange(location: 0, length: attributed.length)
        let docx = folder.appendingPathComponent("posting.docx")
        try attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            .write(to: docx)
        let rtf = folder.appendingPathComponent("posting.rtf")
        try attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            .write(to: rtf)
        let txt = folder.appendingPathComponent("posting.txt")
        try posting.write(to: txt, atomically: true, encoding: .utf8)
        let pdf = folder.appendingPathComponent("posting.pdf")
        try XCTUnwrap(PaginatedPDF.data(attributed)).write(to: pdf)

        for url in [docx, rtf, txt, pdf] {
            let text = try DocumentText.read(url)
            XCTAssertTrue(text.hasPrefix("Senior Backend Engineer"), url.lastPathComponent)
            XCTAssertTrue(text.contains("Go, Postgres, Redis."), url.lastPathComponent)
            XCTAssertFalse(text.contains("\n\n\n"), "blank lines collapse in \(url.lastPathComponent)")
            XCTAssertFalse(text.contains("\r"), url.lastPathComponent)
        }
    }

    func testEmptyAndUnreadableFilesFailClearly() throws {
        let empty = folder.appendingPathComponent("empty.txt")
        try "  \n\n ".write(to: empty, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try DocumentText.read(empty)) { XCTAssertEqual($0 as? DocumentText.Failure, .empty) }
        let junk = folder.appendingPathComponent("junk.docx")
        try Data([0, 1, 2, 3]).write(to: junk)
        XCTAssertThrowsError(try DocumentText.read(junk)) { XCTAssertEqual($0 as? DocumentText.Failure, .unreadable) }
    }

    func testRoleFileRoundTripsAsANewRole() throws {
        var role = RoleProfile(name: "Backend Engineer", company: "Acme", jobDescription: "Payments API.")
        role.plannedQuestions = [PlannedQuestion(text: "Design a rate limiter", family: "System design",
                                                 strongAnswer: "Token bucket, shared state")]
        role.cheaterPrompts[1].instructions = "Bullets only."
        let data = try RoleFile.encode(role)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"format\" : \"interviewcheck.role\""))

        let imported = try RoleFile.decode(data)
        XCTAssertNotEqual(imported.id, role.id, "an import never overwrites the original")
        XCTAssertEqual(imported.displayTitle, "Backend Engineer at Acme")
        XCTAssertEqual(imported.plannedQuestions, role.plannedQuestions)
        XCTAssertEqual(imported.cheaterPrompts, role.cheaterPrompts)

        XCTAssertThrowsError(try RoleFile.decode(Data("{\"format\":\"other\"}".utf8)))
        XCTAssertThrowsError(try RoleFile.decode(Data("not json".utf8)))
    }

    func testDuplicateMakesANamedCopy() {
        let path = NSTemporaryDirectory() + "roles-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = RoleStore(database: SessionDatabase(databasePath: path),
                              defaults: UserDefaults(suiteName: "roles.\(UUID().uuidString)")!)
        let original = store.create(name: "Backend Engineer", company: "Acme")
        let copy = store.duplicate(original.id)
        XCTAssertEqual(copy?.name, "Backend Engineer copy")
        XCTAssertNotEqual(copy?.id, original.id)
        XCTAssertEqual(store.roles.count, 2)
    }
}
