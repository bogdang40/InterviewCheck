import AppKit
import XCTest
@testable import memanager

@MainActor
final class ScreenshotServiceIsolationTests: XCTestCase {
    func testCaptureEntryPointsPreserveFixtureStateWithoutCheckingPermissions() {
        guard TestRuntime.isRunningUnitTests else {
            XCTFail("Capture isolation requires an identified XCTest process")
            return
        }
        let service = ScreenshotService.shared
        let originalScreenshots = service.screenshots
        let originalError = service.lastError
        let originalCapturing = service.isCapturing
        let permissionCheck = AppDefaults.standard.object(forKey: "memanager.permissions.lastCheck") as? Date
        defer {
            service.screenshots = originalScreenshots
            service.lastError = originalError
            service.isCapturing = originalCapturing
        }
        let fixture = Screenshot(image: NSImage(size: NSSize(width: 2, height: 2)), capturedAt: Date())
        service.screenshots = [fixture]
        service.lastError = .noScreen
        service.isCapturing = false

        service.prewarmFreshFullScreenCache()
        service.captureFullScreen()
        service.captureRegion()
        service.openPermissionSettings()
        let fresh = service.captureFreshFullScreenBase64()

        XCTAssertFalse(fresh.succeeded)
        XCTAssertNil(fresh.base64)
        XCTAssertEqual(fresh.failureReason, .captureFailure)
        XCTAssertNil(service.captureFullScreenBase64())
        XCTAssertEqual(service.screenshots.map(\.id), [fixture.id])
        XCTAssertFalse(service.isCapturing, "Tests must not create a region selection window")
        XCTAssertEqual(service.lastError?.localizedDescription, ScreenshotService.ScreenshotError.noScreen.localizedDescription)
        XCTAssertEqual(AppDefaults.standard.object(forKey: "memanager.permissions.lastCheck") as? Date, permissionCheck)
    }
}
