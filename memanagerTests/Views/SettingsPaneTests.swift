import XCTest
@testable import memanager

final class SettingsPaneTests: XCTestCase {
    func testAdminPageOnlyAppearsForAdmins() {
        XCTAssertFalse(SettingsPane.available(isAdmin: false).contains(.admin))
        XCTAssertTrue(SettingsPane.available(isAdmin: true).contains(.admin))
    }

    func testEveryOtherPageIsAlwaysAvailableInDeclarationOrder() {
        let member = SettingsPane.available(isAdmin: false)
        XCTAssertEqual(member, SettingsPane.allCases.filter { $0 != .admin })
        XCTAssertEqual(SettingsPane.available(isAdmin: true), SettingsPane.allCases)
        XCTAssertEqual(member.first, .aiProvider)
        XCTAssertEqual(member.last, .about)
    }

    func testEveryPageHasATitleAndAnIcon() {
        for pane in SettingsPane.allCases {
            XCTAssertFalse(pane.title.isEmpty, "\(pane) needs a title")
            XCTAssertFalse(pane.systemImage.isEmpty, "\(pane) needs an icon")
        }
    }
}
