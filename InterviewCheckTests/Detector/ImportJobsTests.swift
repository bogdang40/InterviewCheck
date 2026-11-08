import XCTest
import InterviewCheckConnectors
@testable import InterviewCheck

private struct JobsATS: JobListing {
    let kind = ConnectorKind.greenhouse
    func verify() async throws -> String { "ok" }
    func openJobs() async throws -> [ExternalJob] {
        [ExternalJob(externalID: "j1", title: "Backend Engineer"), ExternalJob(externalID: "j2", title: "Designer", description: "Draw things.")]
    }
    func job(id: String) async throws -> ExternalJob {
        ExternalJob(externalID: id, title: "Backend Engineer", description: "Own the payments API in Go and Postgres for a fast-growing team.")
    }
}

@MainActor
final class ImportJobsTests: XCTestCase {
    func testImportMakesRolesWithDescriptionsOnce() async throws {
        let path = NSTemporaryDirectory() + "jobs-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = SessionDatabase(databasePath: path)
        let defaults = UserDefaults(suiteName: "jobs.\(UUID().uuidString)")!
        let manager = ConnectorManager(store: MemoryCredentialStore(), database: database, defaults: defaults)
        manager.factory = { _, _, _, _ in JobsATS() }
        try await manager.connect(.greenhouse, fields: ["clientID": "c", "clientSecret": "s"])
        XCTAssertEqual(manager.jobSources, [.greenhouse])
        let roles = RoleStore(database: database, defaults: defaults)

        let jobs = try await manager.openJobs(.greenhouse)
        XCTAssertEqual(jobs.map(\.title), ["Backend Engineer", "Designer"])
        let imported = await manager.importJobs(jobs, from: .greenhouse, roles: roles)
        XCTAssertEqual(imported.map(\.name), ["Backend Engineer", "Designer"])
        XCTAssertEqual(roles.roles.first { $0.name == "Backend Engineer" }?.jobDescription,
                       "Own the payments API in Go and Postgres for a fast-growing team.", "the full description is fetched")
        XCTAssertEqual(roles.roles.first { $0.name == "Designer" }?.externalJobKey, "greenhouse:j2")

        let again = await manager.importJobs(jobs, from: .greenhouse, roles: roles)
        XCTAssertTrue(again.isEmpty, "an imported job is not imported twice")
        XCTAssertEqual(roles.roles.count, 2)
    }
}
