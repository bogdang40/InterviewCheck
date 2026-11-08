import XCTest
@testable import memanager

/// Destructive controller tests own a database independent of every singleton.
@MainActor
class SessionControllerDatabaseTestCase: XCTestCase {
    private var directory: URL!
    var database: SessionDatabase!
    var logger: SessionLogger!
    var controller: SessionController!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = TestRuntime.temporaryDirectory
            .appendingPathComponent("controller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = SessionDatabase(databasePath: directory.appendingPathComponent("sessions.sqlite").path)
        logger = SessionLogger(database: database)
        controller = SessionController(
            workstreamTimelineRepository: WorkstreamTimelineRepository(logger: logger),
            relatedMemoryService: RelatedMemoryService(logger: logger), logger: logger
        )
    }

    override func tearDown() async throws {
        try await super.tearDown()
        defer { directory = nil }
        controller?.stopRuntimeServices()
        weak var remainingController = controller
        weak var remainingLogger = logger
        controller = nil
        logger = nil

        // Timeline loads retain the repository and logger until their main
        // actor publication finishes. Keep the database alive while yielding
        // to those loads, then close it before removing its files.
        let deadline = Date().addingTimeInterval(3)
        while (remainingController != nil || remainingLogger != nil), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard remainingController == nil, remainingLogger == nil else {
            database = nil
            XCTFail("A controller operation still retains the database; keeping its temporary files")
            return
        }

        database?.flush()
        weak var remainingDatabase = database
        database = nil
        guard remainingDatabase == nil else {
            XCTFail("The controller database is still retained; keeping its temporary files")
            return
        }
        if let directory { try FileManager.default.removeItem(at: directory) }
    }
}
