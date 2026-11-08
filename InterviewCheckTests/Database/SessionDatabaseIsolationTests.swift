import XCTest
@testable import InterviewCheck

final class SessionDatabaseIsolationTests: XCTestCase {
    func testSharedDatabaseActuallyOpensOnlyTheCurrentTemporaryTestStore() throws {
        _ = try XCTUnwrap(TestRuntime.isRunningUnitTests ? true : nil,
                          "Refusing to initialize shared storage outside an isolated test host")
        let paths = try SessionDatabase.shared.performSyncThrowing { db in
            let query = try SQLiteStatement(db: db, sql: "PRAGMA database_list")
            var paths: [String: String] = [:]
            while try query.stepRow() {
                if let name = query.columnText(1), let path = query.columnText(2) { paths[name] = path }
            }
            return paths
        }
        let actual = URL(fileURLWithPath: try XCTUnwrap(paths["main"])).resolvingSymlinksInPath()
        let expected = TestRuntime.temporaryDirectory.appendingPathComponent("sessions.sqlite")
            .resolvingSymlinksInPath()
        XCTAssertEqual(actual, expected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: actual.path))
        let production = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("InterviewCheck/db/sessions.sqlite").resolvingSymlinksInPath()
        XCTAssertNotEqual(actual, production)
    }
}
