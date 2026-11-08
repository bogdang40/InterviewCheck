import XCTest
@testable import InterviewCheckConnectors

/// A scripted IMAP server: answers each command and hands the bytes back in
/// small chunks, so literals and lines arrive split like they do over TLS.
final class FakeIMAPServer: IMAPStream, @unchecked Sendable {
    typealias Handler = (String) -> (untagged: [String], status: String)
    private let lock = NSLock()
    private var pending: [UInt8]
    private let handler: Handler
    private(set) var commands: [String] = []
    var chunkSize = 13

    init(greeting: String = "* OK [CAPABILITY IMAP4rev1] ready", handler: @escaping Handler) {
        pending = Array("\(greeting)\r\n".utf8)
        self.handler = handler
    }

    func send(_ data: Data) async throws {
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        let tag = String(line.prefix { $0 != " " })
        let command = String(line.dropFirst(tag.count + 1))
        let (untagged, status) = handler(command)
        lock.withLock {
            commands.append(command)
            for response in untagged { pending.append(contentsOf: Array(response.utf8) + [0x0D, 0x0A]) }
            pending.append(contentsOf: Array("\(tag) \(status)\r\n".utf8))
        }
    }

    func receive() async throws -> Data {
        let chunk: Data? = lock.withLock {
            guard !pending.isEmpty else { return nil }
            let count = min(chunkSize, pending.count)
            defer { pending.removeFirst(count) }
            return Data(pending.prefix(count))
        }
        guard let chunk else { throw IMAPError.closed }
        return chunk
    }

    func close() {}
}

final class MailInviteTests: XCTestCase {
    private let soon = Date(timeIntervalSince1970: 1_794_000_000)   // the sync window starts here

    private func ics(uid: String, summary: String, start: String, sequence: Int = 0, method: String = "REQUEST",
                     extra: String = "") -> String {
        """
        BEGIN:VCALENDAR\r
        METHOD:\(method)\r
        BEGIN:VEVENT\r
        UID:\(uid)\r
        SEQUENCE:\(sequence)\r
        SUMMARY:\(summary)\r
        DTSTART:\(start)\r
        DTEND:\(start.replacingOccurrences(of: "T15", with: "T16"))\r
        ORGANIZER;CN=Sam Recruiter:mailto:sam@acme.com\r
        ATTENDEE;CN=Jane Doe:mailto:jane.doe@gmail.com\r
        ATTENDEE;CN=Lee Engineer:mailto:lee@acme.com\r
        \(extra)END:VEVENT\r
        END:VCALENDAR\r

        """
    }

    private func literal(_ text: String) -> String { "{\(text.utf8.count)}\r\n\(text)" }
    private func base64(_ text: String) -> String { Data(text.utf8).base64EncodedString(options: .lineLength76Characters) }

    private func mailbox() -> FakeIMAPServer {
        let first = ics(uid: "evt-1@acme", summary: "Interview: Jane Doe - Backend Engineer", start: "20261115T150000Z",
                        extra: "LOCATION:https://acme.zoom.us/j/81234567890\r\n")
        // The same invite moved a day later (SEQUENCE 1), sent quoted-printable with a soft line break.
        let moved = ics(uid: "evt-1@acme", summary: "Interview: Jane Doe - Backend Engineer", start: "20261116T150000Z", sequence: 1,
                        extra: "LOCATION:https://acme.zoom.us/j/81234567890\r\n")
        let movedQP = moved.replacingOccurrences(of: "Backend Engineer", with: "Backend =\r\nEngineer")
            .replacingOccurrences(of: "SEQUENCE:1", with: "SEQUENCE=3A1")
        let screen = ics(uid: "evt-2@acme", summary: "Phone screen with Max Roe", start: "20261117T150000Z")
        let cancelled = ics(uid: "evt-2@acme", summary: "Phone screen with Max Roe", start: "20261117T150000Z", method: "CANCEL")
        let lunch = ics(uid: "evt-3@acme", summary: "Team lunch", start: "20261118T150000Z")

        let structures: [Int: String] = [
            101: #"((("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 20 1 NIL NIL NIL)("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "7BIT" 30 1 NIL NIL NIL)("TEXT" "CALENDAR" ("CHARSET" "UTF-8" "METHOD" "REQUEST") NIL NIL "BASE64" 400 6 NIL NIL NIL) "ALTERNATIVE" ("BOUNDARY" "b1") NIL NIL)("APPLICATION" "ICS" ("NAME" "invite.ics") NIL NIL "BASE64" 400 NIL ("ATTACHMENT" ("FILENAME" "invite.ics")) NIL) "MIXED" ("BOUNDARY" "b0") NIL NIL)"#,
            102: #"("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 120 4 NIL NIL NIL)"#,
            103: #"("TEXT" "CALENDAR" ("CHARSET" "UTF-8" "METHOD" "REQUEST") NIL NIL "7BIT" 400 12 NIL NIL NIL)"#,
            104: #"("TEXT" "CALENDAR" ("CHARSET" "UTF-8") NIL NIL "7BIT" 400 12 NIL NIL NIL)"#,
            105: #"("TEXT" "CALENDAR" ("CHARSET" "UTF-8" "METHOD" "REQUEST") NIL NIL "QUOTED-PRINTABLE" 400 12 NIL NIL NIL)"#,
            110: #"(("TEXT" "PLAIN" NIL NIL NIL "7BIT" 20 1 NIL NIL NIL)("APPLICATION" "OCTET-STREAM" ("NAME" "cancel.ics") NIL NIL "BASE64" 400 NIL NIL NIL) "MIXED" ("BOUNDARY" "c") NIL NIL)"#,
        ]
        let bodies: [String: String] = [
            "101 BODY[1.3]": base64(first), "101 BODY[2]": base64(first),
            "103 BODY[1]": screen, "104 BODY[1]": lunch, "105 BODY[1]": movedQP, "110 BODY[2]": base64(cancelled),
        ]
        return FakeIMAPServer { command in
            let upper = command.uppercased()
            if upper.hasPrefix("LOGIN") { return ([], "OK LOGIN completed") }
            if upper.hasPrefix("EXAMINE") { return (["* 42 EXISTS", "* 0 RECENT", "* OK [UIDVALIDITY 7] ok"], "OK [READ-ONLY] done") }
            if upper.hasPrefix("UID SEARCH") { return (["* SEARCH 101 102 103 104 105 110"], "OK done") }
            if upper.hasPrefix("LOGOUT") { return (["* BYE logging out"], "OK done") }
            if upper.hasPrefix("UID FETCH"), upper.contains("BODYSTRUCTURE") {
                let set = command.split(separator: " ")[2].split(separator: ",").compactMap { Int($0) }
                return (set.enumerated().compactMap { index, uid in
                    structures[uid].map { "* \(index + 1) FETCH (UID \(uid) BODYSTRUCTURE \($0))" }
                }, "OK done")
            }
            if upper.hasPrefix("UID FETCH") {
                let uid = command.split(separator: " ")[2]
                let sections = command.matches(of: #/BODY\.PEEK\[([0-9.]+)\]/#).map { String($0.output.1) }
                let parts = sections.compactMap { section in
                    bodies["\(uid) BODY[\(section)]"].map { "BODY[\(section)] \(self.literal($0))" }
                }
                return (["* 1 FETCH (UID \(uid) \(parts.joined(separator: " ")))"], "OK done")
            }
            return ([], "BAD unexpected")
        }
    }

    private func connector(_ server: FakeIMAPServer, fields: [String: String] = [:]) throws -> MailInviteConnector {
        var all = ["email": "lee@gmail.com", "password": "abcd efgh ijkl mnop"]
        all.merge(fields) { $1 }
        return try MailInviteConnector(credentials: ConnectorCredentials(fields: all), openStream: { _, _ in server })
    }

    func testInvitesFollowUpdatesAndCancellations() async throws {
        let server = mailbox()
        let interviews = try await connector(server)
            .upcomingInterviews(from: soon, to: soon.addingTimeInterval(30 * 24 * 3600))
        XCTAssertEqual(interviews.count, 1, "the cancelled screen and the lunch are left out")
        let interview = try XCTUnwrap(interviews.first)
        XCTAssertEqual(interview.source, .imapMail)
        XCTAssertEqual(interview.externalID, "evt-1@acme")
        XCTAssertEqual(interview.startsAt, ISO8601DateFormatter().date(from: "2026-11-16T15:00:00Z"), "the later revision wins")
        XCTAssertEqual(interview.title, "Interview: Jane Doe - Backend Engineer", "the soft line break is joined")
        XCTAssertEqual(interview.candidate?.email, "jane.doe@gmail.com")
        XCTAssertEqual(interview.meetingURL?.host, "acme.zoom.us")
    }

    func testTheMailboxIsOnlyRead() async throws {
        let server = mailbox()
        _ = try await connector(server).upcomingInterviews(from: soon, to: soon.addingTimeInterval(30 * 24 * 3600))
        let verbs = Set(server.commands.map { $0.split(separator: " ").prefix(2).joined(separator: " ").uppercased() })
        XCTAssertTrue(verbs.isSubset(of: ["LOGIN \"LEE@GMAIL.COM\"", "EXAMINE \"INBOX\"", "UID SEARCH", "UID FETCH", "LOGOUT"]), "\(verbs)")
        let fetches = server.commands.filter { $0.uppercased().hasPrefix("UID FETCH") && !$0.contains("BODYSTRUCTURE") }
        XCTAssertFalse(fetches.isEmpty)
        XCTAssertTrue(fetches.allSatisfy { $0.contains("BODY.PEEK[") }, "fetching never marks mail as read")
    }

    func testEveryInviteOptionKeepsNonInterviewTitles() async throws {
        let interviews = try await connector(mailbox(), fields: ["everyInvite": "true"])
            .upcomingInterviews(from: soon, to: soon.addingTimeInterval(30 * 24 * 3600))
        XCTAssertEqual(interviews.map(\.externalID), ["evt-1@acme", "evt-3@acme"])
    }

    func testVerifyShowsTheMailboxAndCount() async throws {
        let label = try await connector(mailbox(), fields: ["folder": "Interviews"]).verify()
        XCTAssertEqual(label, "lee@gmail.com \u{00B7} Interviews (42 messages)")
    }

    func testRejectedSignInExplainsAppPasswords() async throws {
        let normal = FakeIMAPServer { _ in ([], "NO [AUTHENTICATIONFAILED] Invalid credentials") }
        do {
            _ = try await connector(normal).verify()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? ConnectorError, .unauthorized)
        }
        let gmail = FakeIMAPServer { _ in ([], "NO [ALERT] Application-specific password required: https://support.google.com/accounts/answer/185833") }
        do {
            _ = try await connector(gmail).verify()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? ConnectorError, .forbidden("this mailbox needs an app password, not the normal password"))
        }
    }

    func testMissingFolderIsNamed() async throws {
        let server = FakeIMAPServer { command in
            command.uppercased().hasPrefix("EXAMINE") ? ([], "NO Mailbox doesn't exist") : ([], "OK done")
        }
        do {
            _ = try await connector(server, fields: ["folder": "Hiring"]).verify()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The folder \u{201C}Hiring\u{201D} was not found in this mailbox.")
        }
    }

    func testServersAreFoundFromTheAddress() throws {
        XCTAssertEqual(MailInviteConnector.knownHost(for: "a@gmail.com"), "imap.gmail.com")
        XCTAssertEqual(MailInviteConnector.knownHost(for: "a@icloud.com"), "imap.mail.me.com")
        XCTAssertNil(MailInviteConnector.knownHost(for: "a@acme.com"))
        XCTAssertThrowsError(try MailInviteConnector(credentials: ConnectorCredentials(fields: ["email": "a@acme.com", "password": "x"])))
        let custom = try MailInviteConnector(credentials: ConnectorCredentials(fields: ["email": "a@acme.com", "password": "x",
                                                                                         "host": "mail.acme.com:1993"]))
        XCTAssertEqual(custom.host, "mail.acme.com")
        XCTAssertEqual(custom.port, 1993)
    }

    func testQuotingAndDecoding() throws {
        XCTAssertEqual(try IMAPSession.quoted(#"pa"ss\word"#), #""pa\"ss\\word""#)
        XCTAssertThrowsError(try IMAPSession.quoted("pässword"))
        XCTAssertEqual(MIMEDecoding.decode(Data("caf=C3=A9 =\r\nau lait".utf8), encoding: "QUOTED-PRINTABLE", charset: "utf-8"), "café au lait")
        XCTAssertEqual(MIMEDecoding.decode(Data("SGVs\r\nbG8=".utf8), encoding: "BASE64", charset: nil), "Hello")
        XCTAssertEqual(IMAPSession.searchDate(Date(timeIntervalSince1970: 1_794_000_000)), "6-Nov-2026")
    }

    func testCancelledInviteFileIsMarked() {
        let events = ICSParser.events(in: ics(uid: "x", summary: "Interview", start: "20261115T150000Z", method: "CANCEL"))
        XCTAssertEqual(events.first?.isCancelled, true)
        let status = ICSParser.events(in: ics(uid: "x", summary: "Interview", start: "20261115T150000Z", sequence: 3,
                                              extra: "STATUS:CANCELLED\r\n"))
        XCTAssertEqual(status.first?.isCancelled, true)
        XCTAssertEqual(status.first?.sequence, 3)
    }
}

/// Opt-in check of the real TLS connection: reads a server's greeting and
/// capabilities, then logs out. No sign-in. `IMAP_LIVE_HOST=imap.gmail.com swift test --filter LiveIMAP`
final class LiveIMAPGreetingTests: XCTestCase {
    func testGreetingOverTLS() async throws {
        guard let host = ProcessInfo.processInfo.environment["IMAP_LIVE_HOST"] else { throw XCTSkip("set IMAP_LIVE_HOST") }
        let stream = NetworkIMAPStream(host: host, port: 993, timeout: 15)
        try await stream.open()
        let session = IMAPSession(stream: stream)
        try await session.greeting()
        let capabilities = try await session.command("CAPABILITY")
        XCTAssertTrue(capabilities.contains { String(decoding: $0, as: UTF8.self).uppercased().contains("IMAP4") })
        _ = try? await session.command("LOGOUT")
        session.close()
    }
}

final class InviteRevisionTests: XCTestCase {
    func testRepliesCancellationsWithoutTimesAndAlarms() {
        let reply = ICSParser.events(in: "BEGIN:VCALENDAR\r\nMETHOD:REPLY\r\nBEGIN:VEVENT\r\nUID:u1\r\nDTSTART:20261115T160000Z\r\nATTENDEE;PARTSTAT=ACCEPTED:mailto:lee@acme.com\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")
        XCTAssertEqual(reply.first?.isRevision, false, "an Accepted reply is not the organiser's invite")
        let cancel = ICSParser.events(in: "BEGIN:VCALENDAR\r\nMETHOD:CANCEL\r\nBEGIN:VEVENT\r\nUID:u1\r\nSEQUENCE:2\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")
        XCTAssertEqual(cancel.first?.isCancelled, true, "a cancellation without a time still cancels the UID")
        XCTAssertEqual(cancel.first?.id, "u1")
        let alarm = ICSParser.events(in: "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:u2\r\nDTSTART:20261115T160000Z\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\nDESCRIPTION:Reminder\r\nEND:VALARM\r\nDESCRIPTION:Join https://acme.zoom.us/j/1\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")
        XCTAssertEqual(alarm.first?.notes, "Join https://acme.zoom.us/j/1", "the alarm's text is not the event's")
    }

    func testMalformedLiteralsDoNotCrash() {
        XCTAssertEqual(IMAPParser.values(Data("* 1 FETCH (BODY[1] {abc".utf8)).count, 4)
        _ = IMAPParser.values(Data("* 1 FETCH (BODY[1] {99999999999999999999}\r\nx)".utf8))
        _ = IMAPParser.values(Data("* 1 FETCH (BODY[1] {5}\r\nab)".utf8))
        _ = IMAPParser.values(Data("{".utf8))
    }

    func testAReplyInANewerMessageDoesNotReplaceTheInvite() async throws {
        let invite = "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:u9\r\nSEQUENCE:0\r\nSUMMARY:Interview: Jane Doe - Backend Engineer\r\nDTSTART:20261115T150000Z\r\nLOCATION:https://acme.zoom.us/j/81234567890\r\nORGANIZER:mailto:sam@acme.com\r\nATTENDEE;CN=Jane Doe:mailto:jane@gmail.com\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        let reply = "BEGIN:VCALENDAR\r\nMETHOD:REPLY\r\nBEGIN:VEVENT\r\nUID:u9\r\nSEQUENCE:0\r\nSUMMARY:Accepted: Interview\r\nDTSTART:20261115T170000Z\r\nATTENDEE;PARTSTAT=ACCEPTED:mailto:lee@acme.com\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        let server = FakeIMAPServer { command in
            let upper = command.uppercased()
            if upper.hasPrefix("UID SEARCH") { return (["* SEARCH 1 2"], "OK") }
            if upper.contains("BODYSTRUCTURE") {
                let part = #"("TEXT" "CALENDAR" ("CHARSET" "UTF-8") NIL NIL "7BIT" 400 12 NIL NIL NIL)"#
                return (["* 1 FETCH (UID 1 BODYSTRUCTURE \(part))", "* 2 FETCH (UID 2 BODYSTRUCTURE \(part))"], "OK")
            }
            if upper.hasPrefix("UID FETCH 1 ") { return (["* 1 FETCH (UID 1 BODY[1] {\(invite.utf8.count)}\r\n\(invite))"], "OK") }
            if upper.hasPrefix("UID FETCH 2 ") { return (["* 2 FETCH (UID 2 BODY[1] {\(reply.utf8.count)}\r\n\(reply))"], "OK") }
            return ([], "OK")
        }
        let connector = try MailInviteConnector(credentials: ConnectorCredentials(fields: ["email": "lee@gmail.com", "password": "p"]),
                                                openStream: { _, _ in server })
        let interviews = try await connector.upcomingInterviews(from: date("2026-11-07T00:00:00Z"), to: date("2026-11-21T00:00:00Z"))
        XCTAssertEqual(interviews.count, 1)
        XCTAssertEqual(interviews.first?.startsAt, date("2026-11-15T15:00:00Z"), "the reply's time is ignored")
        XCTAssertEqual(interviews.first?.candidate?.email, "jane@gmail.com")
    }
}
