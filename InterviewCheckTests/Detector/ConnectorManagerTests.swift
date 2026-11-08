import XCTest
import InterviewCheckConnectors
@testable import InterviewCheck

/// An ATS stand-in: one interview, its job and a résumé file.
private struct FakeATS: InterviewSource, JobSource, CandidateSource {
    let kind = ConnectorKind.greenhouse
    let start: Date

    func verify() async throws -> String { "acme.greenhouse.io" }

    func upcomingInterviews(from: Date, to: Date) async throws -> [ExternalInterview] {
        [ExternalInterview(source: .greenhouse, externalID: "901", title: "Technical interview", startsAt: start,
                           candidate: ExternalCandidate(externalID: "c7", name: "Jane Doe", email: "jane@example.com",
                                                        resume: ExternalFile(kind: .resume, filename: "jane.txt",
                                                                             url: URL(string: "https://x/r")!, needsAuth: true)),
                           job: ExternalJob(externalID: "j4", title: "Backend Engineer", company: "Acme"),
                           applicationID: "a3")]
    }

    func job(id: String) async throws -> ExternalJob {
        ExternalJob(externalID: id, title: "Backend Engineer", description: "Own the payments API in Go and Postgres.")
    }

    func candidate(id: String) async throws -> ExternalCandidate { ExternalCandidate(name: "Jane Doe") }

    func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        let url = folder.appendingPathComponent(file.filename)
        try "Jane Doe\nSix years building payment systems.".write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

@MainActor
final class ConnectorManagerTests: XCTestCase {
    func testConnectSyncPrepareAndDisconnect() async throws {
        let path = NSTemporaryDirectory() + "connectors-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = SessionDatabase(databasePath: path)
        let defaults = UserDefaults(suiteName: "connectors.\(UUID().uuidString)")!
        let store = MemoryCredentialStore()
        let manager = ConnectorManager(store: store, database: database, defaults: defaults)
        let start = Date().addingTimeInterval(3600)
        manager.factory = { kind, _, _, _ in
            guard kind == .greenhouse else { throw ConnectorError.notConnected }
            return FakeATS(start: start)
        }

        try await manager.connect(.greenhouse, fields: ["apiKey": "secret"])
        XCTAssertEqual(manager.account(.greenhouse)?.label, "acme.greenhouse.io")
        XCTAssertNil(manager.account(.greenhouse)?.lastError)
        XCTAssertEqual(store.load("greenhouse")?["apiKey"], "secret")
        XCTAssertEqual(manager.upcoming.map(\.candidate?.name), ["Jane Doe"])

        // A second manager reads the same accounts and cached interviews.
        let reopened = ConnectorManager(store: store, database: database, defaults: defaults)
        XCTAssertEqual(reopened.accounts.map(\.kind), [.greenhouse])
        XCTAssertEqual(reopened.upcoming.count, 1)

        let roles = RoleStore(database: database, defaults: defaults)
        let controller = InterviewController(timeline: InterviewTimeline(), database: database,
                                             settings: DetectorSettings(defaults: defaults))
        let missing = await manager.prepare(manager.upcoming[0], controller: controller, roles: roles)
        XCTAssertEqual(missing, [])
        XCTAssertEqual(controller.candidateName, "Jane Doe")
        XCTAssertEqual(controller.externalRef, "greenhouse:901")
        XCTAssertEqual(controller.resumeFileName, "jane.txt")
        XCTAssertTrue(controller.resumeText.contains("payment systems"))
        let role = try XCTUnwrap(roles.selectedRole)
        XCTAssertEqual(role.name, "Backend Engineer")
        XCTAssertEqual(role.externalJobKey, "greenhouse:j4")
        XCTAssertEqual(role.jobDescription, "Own the payments API in Go and Postgres.")

        // Preparing again reuses the role.
        await manager.prepare(manager.upcoming[0], controller: controller, roles: roles)
        XCTAssertEqual(roles.roles.count, 1)

        manager.disconnect(.greenhouse)
        XCTAssertNil(store.load("greenhouse"))
        XCTAssertTrue(manager.upcoming.isEmpty)
        XCTAssertTrue(manager.accounts.isEmpty)
    }

    func testFailedSyncIsShownOnTheAccount() async throws {
        let path = NSTemporaryDirectory() + "connectors-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let manager = ConnectorManager(store: MemoryCredentialStore(), database: SessionDatabase(databasePath: path),
                                       defaults: UserDefaults(suiteName: "connectors.\(UUID().uuidString)")!)
        var calls = 0
        manager.factory = { _, _, _, _ in
            calls += 1
            if calls == 1 { return FakeATS(start: Date().addingTimeInterval(60)) }
            throw ConnectorError.unauthorized
        }
        try await manager.connect(.greenhouse, fields: ["apiKey": "k"])
        XCTAssertEqual(manager.account(.greenhouse)?.lastError, ConnectorError.unauthorized.localizedDescription)
    }
}
