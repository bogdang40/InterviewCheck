import XCTest
@testable import memanager

@MainActor
final class SessionControllerMLGuideDisableTests: XCTestCase {
    private var controller: SessionController {
        SessionController.shared
    }

    override func setUp() {
        super.setUp()
        controller.resetSessionStateForTesting()
    }

    func testMLGuideEntryPointsStayDisabled() {
        controller.isMLGuideViewVisible = true
        controller.isMLGuideLoading = true
        controller.mlGuideResponse = "stale response"

        controller.showMLGuide(clearInputs: false)
        XCTAssertFalse(controller.isMLGuideViewVisible)
        XCTAssertFalse(controller.isMLGuideLoading)
        XCTAssertNil(controller.mlGuideResponse)

        controller.isMLGuideViewVisible = true
        controller.isMLGuideLoading = true
        controller.mlGuideResponse = "stale response"

        controller.triggerMLGuide()
        XCTAssertFalse(controller.isMLGuideViewVisible)
        XCTAssertFalse(controller.isMLGuideLoading)
        XCTAssertNil(controller.mlGuideResponse)

        controller.isMLGuideViewVisible = true
        controller.isMLGuideLoading = true
        controller.mlGuideResponse = "stale response"

        controller.triggerMLGuideFollowUp()
        XCTAssertFalse(controller.isMLGuideViewVisible)
        XCTAssertFalse(controller.isMLGuideLoading)
        XCTAssertNil(controller.mlGuideResponse)
    }

    func testNavigationActionsClearMLGuideVisibility() {
        controller.isMLGuideViewVisible = true
        controller.showQuickAssist(clearInputs: false)
        XCTAssertFalse(controller.isMLGuideViewVisible)

        controller.isMLGuideViewVisible = true
        controller.showTranscriptLog()
        XCTAssertFalse(controller.isMLGuideViewVisible)

        controller.isMLGuideViewVisible = true
        controller.selectSection(.implementation)
        XCTAssertFalse(controller.isMLGuideViewVisible)
    }
}
