import XCTest
import InterviewCheckConnectors
@testable import InterviewCheck

private struct OneInterview: InterviewSource {
    let kind = ConnectorKind.appleCalendar
    let start: Date
    var link = "https://acme.zoom.us/j/81234567890"
    func verify() async throws -> String { "1 calendar" }
    func upcomingInterviews(from: Date, to: Date) async throws -> [ExternalInterview] {
        [ExternalInterview(source: .appleCalendar, externalID: "past", title: "Interview: Old", startsAt: start.addingTimeInterval(-7200),
                           endsAt: start.addingTimeInterval(-5400), candidate: ExternalCandidate(name: "Old Candidate")),
         ExternalInterview(source: .appleCalendar, externalID: "next", title: "Interview: Lee Park", startsAt: start,
                           meetingURL: URL(string: link), candidate: ExternalCandidate(name: "Lee Park"))]
    }
}

@MainActor
final class InterviewAutomationTests: XCTestCase {
    func testPrepareNextPicksTheNextInterviewNotOneThatEnded() async throws {
        let path = NSTemporaryDirectory() + "automation-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = SessionDatabase(databasePath: path)
        let defaults = UserDefaults(suiteName: "automation.\(UUID().uuidString)")!
        let manager = ConnectorManager(store: MemoryCredentialStore(), database: database, defaults: defaults)
        let controller = InterviewController(timeline: InterviewTimeline(), database: database, settings: DetectorSettings(defaults: defaults))

        let none = await InterviewAutomation.prepareNext(manager: manager, controller: controller)
        XCTAssertEqual(none, "Connect a calendar, mailbox or ATS in Connections first.")

        manager.factory = { _, _, _, _ in OneInterview(start: Date().addingTimeInterval(1800)) }
        try await manager.connect(.appleCalendar, fields: [:])
        XCTAssertEqual(InterviewAutomation.nextInterview(manager: manager)?.externalID, "next")
        let message = await InterviewAutomation.prepareNext(manager: manager, controller: controller)
        XCTAssertTrue(message.hasPrefix("Prepared Lee Park at "), message)
        XCTAssertEqual(controller.candidateName, "Lee Park")
    }

    func testJoinNextPreparesOnceAndOpensTheMeeting() async throws {
        let path = NSTemporaryDirectory() + "automation-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = SessionDatabase(databasePath: path)
        let defaults = UserDefaults(suiteName: "automation.\(UUID().uuidString)")!
        let manager = ConnectorManager(store: MemoryCredentialStore(), database: database, defaults: defaults)
        let controller = InterviewController(timeline: InterviewTimeline(), database: database, settings: DetectorSettings(defaults: defaults))
        manager.factory = { _, _, _, _ in OneInterview(start: Date().addingTimeInterval(1800)) }
        try await manager.connect(.appleCalendar, fields: [:])
        var opened: [URL] = []
        var joined: [String] = []
        let first = await InterviewAutomation.joinNext(manager: manager, controller: controller, open: { opened.append($0) },
                                                       joined: { joined.append($0) })
        XCTAssertTrue(first.hasPrefix("Prepared Lee Park") && first.hasSuffix("Opened the Zoom link."), first)
        XCTAssertEqual(controller.candidateName, "Lee Park")
        controller.resumeText = "Pasted"
        let second = await InterviewAutomation.joinNext(manager: manager, controller: controller, open: { opened.append($0) },
                                                        joined: { joined.append($0) })
        XCTAssertEqual(second, "Opened the Zoom link.", "already prepared: the setup is left as it is")
        XCTAssertEqual(controller.resumeText, "Pasted")
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(joined, ["appleCalendar:next", "appleCalendar:next"])
    }

    func testJoinNextNeverOpensAnUnsafeOrUnknownLink() async throws {
        for link in ["file:///Applications/Calculator.app", "smb://files.example.com/share", "https://evil.example.com/j/1"] {
            let path = NSTemporaryDirectory() + "automation-\(UUID().uuidString).sqlite"
            defer { try? FileManager.default.removeItem(atPath: path) }
            let database = SessionDatabase(databasePath: path)
            let defaults = UserDefaults(suiteName: "automation.\(UUID().uuidString)")!
            let manager = ConnectorManager(store: MemoryCredentialStore(), database: database, defaults: defaults)
            let controller = InterviewController(timeline: InterviewTimeline(), database: database,
                                                 settings: DetectorSettings(defaults: defaults))
            let source = OneInterview(start: Date().addingTimeInterval(1800), link: link)
            manager.factory = { _, _, _, _ in source }
            try await manager.connect(.appleCalendar, fields: [:])
            var opened: [URL] = []
            var joined: [String] = []
            let said = await InterviewAutomation.joinNext(manager: manager, controller: controller, open: { opened.append($0) },
                                                          joined: { joined.append($0) })
            XCTAssertTrue(opened.isEmpty, link)
            XCTAssertTrue(joined.isEmpty, link)
            XCTAssertFalse(said.contains("Opened"), said)
        }
    }

    func testOnlyOwnURLsAreHandled() {
        XCTAssertFalse(InterviewAutomation.handle(URL(string: "https://example.com/prepare-next")!))
        XCTAssertFalse(InterviewAutomation.handle(URL(string: "interviewcheck://billing/success")!), "left to the account code")
        XCTAssertTrue(InterviewAutomation.handle(URL(string: "interviewcheck://sync")!))
    }
}
