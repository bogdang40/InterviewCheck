import XCTest
@testable import memanager

@MainActor
final class SolveRequestAdmissionTests: SessionControllerDatabaseTestCase {
    func testCancelledSolveTaskDoesNotCreateAuditTracking() async {
        await assertCancelledAdmission(systemDesign: false)
    }

    func testCancelledDesignTaskDoesNotCreateAuditTracking() async {
        await assertCancelledAdmission(systemDesign: true)
    }

    private func assertCancelledAdmission(systemDesign: Bool) async {
        controller.aiProvider = nil
        controller.errorMessage = nil
        controller.isLoading = true
        let controller = self.controller!
        let sessionID = controller.session.id
        let requestID = controller.activeSolveRequestID
        // The child cannot enter MainActor before this test yields. Cancel it
        // first, while its session/request/loading identity still matches.
        let request = Task { @MainActor in
            if systemDesign {
                await controller.runSolveSystemDesign(sessionID: sessionID, requestID: requestID)
            } else {
                await controller.runSolve(sessionID: sessionID, requestID: requestID)
            }
        }
        request.cancel()
        await request.value
        database.flush()

        XCTAssertTrue(database.getAPICallsForSession(sessionId: sessionID.uuidString).isEmpty)
        XCTAssertTrue(database.getProviderStats().isEmpty)
        XCTAssertEqual(database.performSync { _ in database.apiCallOwners.count }, 0)
        XCTAssertNil(controller.errorMessage)
        controller.isLoading = false
    }
}
