import Foundation
import XCTest
@testable import memanager

final class AppDefaultsIsolationTests: XCTestCase {
    func testHostedTestsUseSeparatePreferences() throws {
        XCTAssertTrue(TestRuntime.isRunningUnitTests)
        // This read deliberately checks the real host domain without writing it.
        let production = UserDefaults.standard
        let isolated = try isolatedDefaults()

        let key = "memanager.testIsolation.\(UUID().uuidString)"
        XCTAssertNil(production.object(forKey: key))
        isolated.set("isolated fixture", forKey: key)
        defer { isolated.removeObject(forKey: key) }

        XCTAssertEqual(isolated.string(forKey: key), "isolated fixture")
        XCTAssertNil(production.object(forKey: key))
        XCTAssertTrue(AppDefaults.standard === isolated)
    }

    @MainActor
    func testSharedModeStorePersistsOnlyIntoIsolatedPreferences() throws {
        _ = try isolatedDefaults()
        let modes = ModeStore.shared
        let originals = modes.modes
        let originalActiveID = modes.activeModeID
        defer { modes.replaceAll(originals, activeID: originalActiveID) }

        let fixture = Mode(title: "Isolated mode", prompt: "Test context")
        modes.replaceAll([fixture], activeID: fixture.id)

        let data = try XCTUnwrap(AppDefaults.standard.data(forKey: "memanager.modes"))
        XCTAssertEqual(try JSONDecoder().decode([Mode].self, from: data).map(\.id), [fixture.id])
        XCTAssertEqual(ModeStoreBridge.activeMode()?.id, fixture.id)
    }

    private func isolatedDefaults(file: StaticString = #filePath, line: UInt = #line) throws -> UserDefaults {
        let defaults = AppDefaults.standard
        return try XCTUnwrap(
            defaults !== UserDefaults.standard ? defaults : nil,
            "Refusing to exercise persistence against the production defaults domain",
            file: file,
            line: line
        )
    }
}
