import XCTest
@testable import InterviewCheckConnectors

final class MailResumeTests: XCTestCase {
    private let pdf = "%PDF-1.4 Jane Doe, six years of payments in Go"

    private func server(searchHits: String = "* SEARCH 31 32") -> FakeIMAPServer {
        let header31 = "Subject: =?UTF-8?Q?CV_for_tomorrow=E2=80=99s_interview?=\r\nFrom: Sam Recruiter <sam@acme.com>\r\nDate: Thu, 5 Nov 2026 10:12:00 -0500\r\n\r\n"
        let header32 = "Subject: Candidates for next week\r\nFrom: Sam Recruiter <sam@acme.com>\r\nDate: Fri, 6 Nov 2026 09:00:00 -0500\r\n\r\n"
        let structure31 = #"(("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 40 2 NIL NIL NIL)("APPLICATION" "PDF" ("NAME" "Jane_Doe_CV.pdf") NIL NIL "BASE64" 2000 NIL ("ATTACHMENT" ("FILENAME" "Jane_Doe_CV.pdf")) NIL) "MIXED" ("BOUNDARY" "x") NIL NIL)"#
        let structure32 = #"(("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 40 2 NIL NIL NIL)("APPLICATION" "PDF" ("NAME" "Max_Roe_CV.pdf") NIL NIL "BASE64" 2000 NIL NIL NIL) "MIXED" ("BOUNDARY" "x") NIL NIL)"#
        let encoded = Data(pdf.utf8).base64EncodedString(options: .lineLength76Characters)
        return FakeIMAPServer { command in
            let upper = command.uppercased()
            if upper.hasPrefix("UID SEARCH") { return ([searchHits], "OK") }
            if upper.contains("BODYSTRUCTURE") {
                return (["* 1 FETCH (UID 31 BODYSTRUCTURE \(structure31) BODY[HEADER.FIELDS (SUBJECT FROM DATE)] {\(header31.utf8.count)}\r\n\(header31))",
                         "* 2 FETCH (UID 32 BODYSTRUCTURE \(structure32) BODY[HEADER.FIELDS (SUBJECT FROM DATE)] {\(header32.utf8.count)}\r\n\(header32))"], "OK")
            }
            if upper.hasPrefix("UID FETCH 31 ") { return (["* 1 FETCH (UID 31 BODY[2] {\(encoded.utf8.count)}\r\n\(encoded))"], "OK") }
            return ([], "OK")
        }
    }

    private func connector(_ server: FakeIMAPServer, fields: [String: String] = [:]) throws -> MailInviteConnector {
        var all = ["email": "lee@gmail.com", "password": "p"]
        all.merge(fields) { $1 }
        return try MailInviteConnector(credentials: ConnectorCredentials(fields: all), openStream: { _, _ in server }, cache: MailInviteCache())
    }

    func testTheCandidatesEmailedCVIsFound() async throws {
        let mail = server()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let found = try await connector(mail).findResume(for: ExternalCandidate(name: "Jane Doe", email: "jane@gmail.com"), into: folder)
        let resume = try XCTUnwrap(found)
        XCTAssertEqual(resume.filename, "Jane_Doe_CV.pdf", "another candidate's CV in a newer message is not taken")
        XCTAssertEqual(try String(contentsOf: resume.file, encoding: .utf8), pdf)
        XCTAssertEqual(resume.origin, "Sam Recruiter <sam@acme.com>, Thu, 5 Nov 2026")
        let search = try XCTUnwrap(mail.commands.first { $0.uppercased().hasPrefix("UID SEARCH") })
        XCTAssertTrue(search.contains(#"OR TEXT "Jane Doe" TEXT "jane@gmail.com""#), search)
        XCTAssertTrue(mail.commands.filter { $0.uppercased().hasPrefix("UID FETCH") }.allSatisfy { !$0.contains("BODY[") || $0.contains("PEEK") },
                      "nothing is marked as read")
    }

    func testNothingWhenNoAttachmentNamesTheCandidateOrWhenTurnedOff() async throws {
        let folder = FileManager.default.temporaryDirectory
        let other = try await connector(server()).findResume(for: ExternalCandidate(name: "Ana Pop"), into: folder)
        XCTAssertNil(other)
        let off = try await connector(server(), fields: ["noResumes": "true"])
            .findResume(for: ExternalCandidate(name: "Jane Doe"), into: folder)
        XCTAssertNil(off)
    }

    func testMatchingRules() {
        let jane = MailInviteConnector.nameTokens("Jane Doe")
        XCTAssertEqual(MailInviteConnector.matchStrength(filename: "Jane-Doe.pdf", subject: "", tokens: jane), 2)
        XCTAssertEqual(MailInviteConnector.matchStrength(filename: "DOE_resume_2026.docx", subject: "", tokens: jane), 2, "the surname is enough")
        XCTAssertEqual(MailInviteConnector.matchStrength(filename: "CV.pdf", subject: "Fwd: Jane Doe for Backend", tokens: jane), 1)
        XCTAssertEqual(MailInviteConnector.matchStrength(filename: "offer-letter.pdf", subject: "Jane Doe", tokens: jane), 0,
                       "a document that is not a CV in a message about her")
        XCTAssertEqual(MailInviteConnector.matchStrength(filename: "Résumé.pdf", subject: "Résumé — José Núñez",
                                                         tokens: MailInviteConnector.nameTokens("Jose Nunez")), 1, "accents ignored")
    }

    func testEncodedHeaders() {
        XCTAssertEqual(MIMEDecoding.headerText("=?UTF-8?B?UsOpc3Vtw6k=?= =?UTF-8?Q?_Jane?="), "Résumé Jane")
        XCTAssertEqual(MIMEDecoding.headerText("=?iso-8859-1?Q?Jos=E9?= N"), "José N")
        XCTAssertEqual(MIMEDecoding.headerText("Plain subject"), "Plain subject")
    }
}

final class OutlookResumeTests: XCTestCase {
    func testOutlookMailIsSearchedOnlyWhenTurnedOn() async throws {
        let stub = StubTransport()
        stub.on("GET", "attachments/A2/$value", json: "%PDF-1.4 Jane")
        stub.on("GET", "me/messages/M1/attachments", json: #"{"value":[{"id":"A1","name":"logo.png","contentType":"image/png","size":2000},{"id":"A2","name":"Jane Doe - CV.pdf","contentType":"application/pdf","size":90000}]}"#)
        stub.on("GET", "me/messages?", json: #"{"value":[{"id":"M1","subject":"CV","hasAttachments":true,"receivedDateTime":"\#(DateParsing.iso(Date().addingTimeInterval(-86_400)))","from":{"emailAddress":{"name":"Sam Recruiter","address":"sam@contoso.com"}}}]}"#)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let off = try MicrosoftGraphConnector(credentials: ConnectorCredentials(fields: [:]), transport: stub, accessToken: { "t" })
        let none = try await off.findResume(for: ExternalCandidate(name: "Jane Doe"), into: folder)
        XCTAssertNil(none)
        XCTAssertTrue(stub.requests.isEmpty, "no mail is read unless turned on")

        let credentials = ConnectorCredentials(fields: ["mailResumes": "true"])
        let on = try MicrosoftGraphConnector(credentials: credentials, transport: stub, accessToken: { "t" })
        let found = try await on.findResume(for: ExternalCandidate(name: "Jane Doe", email: "jane@example.com"), into: folder)
        XCTAssertEqual(found?.filename, "Jane Doe - CV.pdf")
        XCTAssertTrue(found?.origin.hasPrefix("Sam Recruiter, ") == true)
        XCTAssertEqual(stub.requests(containing: "me/messages?").count, 2, "the name and the email are searched")
        XCTAssertTrue(MicrosoftConnectorProvider.provider(credentials).scopes.contains("Mail.Read"))
        XCTAssertFalse(MicrosoftConnectorProvider.provider(ConnectorCredentials(fields: [:])).scopes.contains("Mail.Read"))
    }
}
