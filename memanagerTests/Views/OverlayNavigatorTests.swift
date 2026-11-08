import XCTest
@testable import memanager

@MainActor
final class OverlayNavigatorTests: XCTestCase {
    func testStartsOnTheMentorSurface() {
        let navigator = OverlayNavigator()
        XCTAssertEqual(navigator.screen, .mentor)
        XCTAssertTrue(navigator.isShowingMentor)
    }

    func testShowSwitchesScreensAndReturnToMentorComesBack() {
        let navigator = OverlayNavigator()
        navigator.show(.workspaces)
        XCTAssertEqual(navigator.screen, .workspaces)
        XCTAssertFalse(navigator.isShowingMentor)
        navigator.show(.settings)
        XCTAssertEqual(navigator.screen, .settings)
        navigator.returnToMentor()
        XCTAssertEqual(navigator.screen, .mentor)
    }

    func testToggleOpensAScreenAndTogglingItAgainReturnsToMentor() {
        let navigator = OverlayNavigator()
        navigator.toggle(.knowledge)
        XCTAssertEqual(navigator.screen, .knowledge)
        navigator.toggle(.knowledge)
        XCTAssertEqual(navigator.screen, .mentor)
        navigator.toggle(.knowledge)
        navigator.toggle(.settings)
        XCTAssertEqual(navigator.screen, .settings, "toggling a different screen switches instead of closing")
    }

    func testShowIsIdempotentAndDoesNotRepublish() {
        let navigator = OverlayNavigator(screen: .settings)
        var changes = 0
        let subscription = navigator.$screen.dropFirst().sink { _ in changes += 1 }
        navigator.show(.settings)
        navigator.show(.settings)
        XCTAssertEqual(changes, 0)
        navigator.show(.mentor)
        XCTAssertEqual(changes, 1)
        subscription.cancel()
    }

    func testPrimaryTabsKeepTheirDestinationAndRememberPreparationPage() {
        let navigator = OverlayNavigator()
        navigator.select(.prepare)
        XCTAssertEqual(navigator.screen, .workspaces)
        navigator.show(.knowledge)
        navigator.select(.review)
        navigator.select(.prepare)
        XCTAssertEqual(navigator.screen, .knowledge)
        navigator.select(.prepare)
        XCTAssertEqual(navigator.screen, .knowledge)
    }

    func testSettingsReturnsToActualPriorDestinationAndTargetsRecoveryPane() {
        let navigator = OverlayNavigator(screen: .history)
        navigator.showSettings(.permissions)
        XCTAssertEqual(navigator.screen, .settings)
        XCTAssertEqual(navigator.settingsPane, .permissions)
        navigator.select(.settings)
        navigator.toggle(.settings)
        XCTAssertEqual(navigator.screen, .history)
        navigator.show(.knowledge)
        navigator.showSettings(.account)
        navigator.toggle(.settings)
        XCTAssertEqual(navigator.screen, .knowledge)
    }

    func testSwitchableScreensExcludeTheMentorSurface() {
        XCTAssertEqual(OverlayScreen.switchable, [.workspaces, .knowledge, .practice, .history, .settings])
        XCTAssertFalse(OverlayScreen.switchable.contains(.mentor))
        for screen in OverlayScreen.allCases {
            XCTAssertFalse(screen.title.isEmpty)
            XCTAssertFalse(screen.systemImage.isEmpty)
        }
    }
}
