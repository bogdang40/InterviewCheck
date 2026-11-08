import XCTest
import InterviewCheckConnectors
@testable import InterviewCheck

private struct OneInterview: InterviewSource {
    let kind = ConnectorKind.appleCalendar
    let start: Date
    func verify() async throws -> String { "1 calendar" }
    func upcomingInterviews(from: Date, to: Date) async throws -> [ExternalInterview] {
        [ExternalInterview(source: .appleCalendar, externalID: "past", title: "Interview: Old", startsAt: start.addingTimeInterval(-7200),
                           endsAt: start.addingTimeInterval(-5400), candidate: ExternalCandidate(name: "Old Candidate")),
         ExternalInterview(source: .appleCalendar, externalID: "next", title: "Interview: Lee Park", startsAt: start,
                           candidate: ExternalCandidate(name: "Lee Park"))]
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
        XCTAssertEqual(none, "Connect a calendar or ATS in Connections first.")

        manager.factory = { _, _, _, _ in OneInterview(start: Date().addingTimeInterval(1800)) }
        try await manager.connect(.appleCalendar, fields: [:])
        XCTAssertEqual(InterviewAutomation.nextInterview(manager: manager)?.externalID, "next")
        let message = await InterviewAutomation.prepareNext(manager: manager, controller: controller)
        XCTAssertTrue(message.hasPrefix("Prepared Lee Park at "), message)
        XCTAssertEqual(controller.candidateName, "Lee Park")
    }

    func testOnlyOwnURLsAreHandled() {
        XCTAssertFalse(InterviewAutomation.handle(URL(string: "https://example.com/prepare-next")!))
        XCTAssertFalse(InterviewAutomation.handle(URL(string: "interviewcheck://billing/success")!), "left to the account code")
        XCTAssertTrue(InterviewAutomation.handle(URL(string: "interviewcheck://sync")!))
    }
}
