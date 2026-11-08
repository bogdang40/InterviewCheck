import XCTest
@testable import memanager

final class AppearancePreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.memanager.tests.appearance.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testMissingAndNonfiniteValuesRestoreReadableDefaults() {
        for value in [0, -1, Double.nan, .infinity, -.infinity] {
            defaults.set(value, forKey: "memanager.overlayOpacity")
            defaults.set(value, forKey: "memanager.fontSize")
            defaults.set(value, forKey: "memanager.overlayWidth")
            let restored = AppearancePreferences(defaults: defaults)
            XCTAssertEqual(restored.opacity, 0.95)
            XCTAssertEqual(restored.fontSize, 14)
            XCTAssertEqual(restored.width, 800)
        }
    }

    func testOutOfRangePersistedValuesRespectAppearanceControls() {
        defaults.set(5, forKey: "memanager.overlayOpacity")
        defaults.set(1000, forKey: "memanager.fontSize")
        defaults.set(12, forKey: "memanager.overlayWidth")
        let restored = AppearancePreferences(defaults: defaults)
        XCTAssertEqual(restored.opacity, 1)
        XCTAssertEqual(restored.fontSize, 24)
        XCTAssertEqual(restored.width, 400)
    }

    func testValidUserPreferencesArePreserved() {
        defaults.set(0.73, forKey: "memanager.overlayOpacity")
        defaults.set(18, forKey: "memanager.fontSize")
        defaults.set(926, forKey: "memanager.overlayWidth")
        let restored = AppearancePreferences(defaults: defaults)
        XCTAssertEqual(restored.opacity, 0.73)
        XCTAssertEqual(restored.fontSize, 18)
        XCTAssertEqual(restored.width, 926)
    }
}
