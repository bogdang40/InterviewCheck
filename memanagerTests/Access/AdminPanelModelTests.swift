import XCTest
@testable import memanager

@MainActor
final class AdminPanelModelTests: XCTestCase {
    @MainActor
    private final class FakeAdminClient: AdminAPIClienting {
        var pages: [AdminUserPage] = []
        var updates: [(String, AdminUserPatch)] = []
        var failNext = false
        var pauseNextUpdate = false
        var onUpdateSuspended: (() -> Void)?
        var updateContinuation: CheckedContinuation<Void, Never>?

        func stats(token: String) async throws -> AdminStats {
            AdminStats(totalUsers: 3, admins: 1, liveSubscriptions: 1)
        }

        func users(token: String, query: String?, cursor: String?) async throws -> AdminUserPage {
            if failNext { failNext = false; throw AccessAPIError.server(status: 500, code: "internal_error", message: "boom") }
            return pages.isEmpty ? AdminUserPage(users: [], nextCursor: nil) : pages.removeFirst()
        }

        func update(token: String, userID: String, patch: AdminUserPatch) async throws -> AdminUserView {
            updates.append((userID, patch))
            if pauseNextUpdate {
                pauseNextUpdate = false
                await withCheckedContinuation {
                    updateContinuation = $0
                    onUpdateSuspended?()
                }
            }
            var view = AdminPanelModelTests.view(id: userID)
            if patch.role == .admin {
                view = AdminUserView(user: AccountUser(id: userID, email: view.user.email, role: .admin, disabled: false, createdAt: view.user.createdAt, trialEndsAt: nil, complimentaryUntil: nil), entitlement: view.entitlement, subscription: nil, lastLoginAt: nil)
            }
            return view
        }

        func audit(token: String) async throws -> [AdminAuditEntry] { [] }

        func completePausedUpdate() {
            let continuation = updateContinuation
            updateContinuation = nil
            continuation?.resume()
        }
    }

    nonisolated static func view(id: String) -> AdminUserView {
        AdminUserView(
            user: AccountUser(id: id, email: "\(id)@example.com", role: .user, disabled: false, createdAt: "2026-01-01T00:00:00Z", trialEndsAt: nil, complimentaryUntil: nil),
            entitlement: Entitlement(active: false, source: .none, expiresAt: nil, graceUntil: "2026-01-01T00:00:00Z", plan: nil, subscriptionStatus: nil),
            subscription: nil,
            lastLoginAt: nil
        )
    }

    func testLoadFetchesStatsAndFirstPageThenAppendsNextPage() async {
        let client = FakeAdminClient()
        client.pages = [
            AdminUserPage(users: [Self.view(id: "a"), Self.view(id: "b")], nextCursor: "c1"),
            AdminUserPage(users: [Self.view(id: "c")], nextCursor: nil),
        ]
        let model = AdminPanelModel(client: client, tokenProvider: { "mm_t" })
        await model.load()
        XCTAssertEqual(model.users.map(\.id), ["a", "b"])
        XCTAssertEqual(model.stats?.totalUsers, 3)
        XCTAssertEqual(model.nextCursor, "c1")
        await model.load(reset: false)
        XCTAssertEqual(model.users.map(\.id), ["a", "b", "c"])
        XCTAssertNil(model.nextCursor)
    }

    func testLoadWithoutTokenDoesNothingAndErrorsSurfaceAsMessage() async {
        let client = FakeAdminClient()
        let silent = AdminPanelModel(client: client, tokenProvider: { nil })
        await silent.load()
        XCTAssertTrue(silent.users.isEmpty)
        XCTAssertNil(silent.stats)

        client.failNext = true
        let failing = AdminPanelModel(client: client, tokenProvider: { "mm_t" })
        await failing.load()
        XCTAssertEqual(failing.message, "boom")
    }

    func testMutationsReplaceTheRowAndNeverEncodeNullByAccident() async {
        let client = FakeAdminClient()
        client.pages = [AdminUserPage(users: [Self.view(id: "a")], nextCursor: nil)]
        let model = AdminPanelModel(client: client, tokenProvider: { "mm_t" })
        await model.load()

        await model.setRole(.admin, for: model.users[0])
        XCTAssertEqual(model.users[0].user.role, .admin)
        XCTAssertEqual(client.updates.last?.1.role, .admin)

        await model.grant(days: 30, to: model.users[0])
        guard case .some(.some(let until)) = client.updates.last?.1.complimentaryUntil else {
            return XCTFail("grant must send a concrete date")
        }
        XCTAssertGreaterThan(until.timeIntervalSinceNow, 29 * 86_400)

        await model.clearGrant(for: model.users[0])
        guard case .some(.none) = client.updates.last?.1.complimentaryUntil else {
            return XCTFail("clear must send an explicit null")
        }
        XCTAssertTrue(model.message?.contains("Updated") ?? false)
    }

    func testRepeatedAccountMutationIsRejectedWhileItsFirstRequestIsPending() async {
        let client = FakeAdminClient()
        client.pauseNextUpdate = true
        let suspended = expectation(description: "First update installed its continuation")
        let completed = expectation(description: "First update finished after release")
        client.onUpdateSuspended = { suspended.fulfill() }
        let model = AdminPanelModel(client: client, tokenProvider: { "fixture" })
        let user = Self.view(id: "a")
        let first = Task {
            await model.setRole(.admin, for: user)
            completed.fulfill()
        }
        defer {
            client.pauseNextUpdate = false
            client.completePausedUpdate()
            first.cancel()
        }
        await fulfillment(of: [suspended], timeout: 2)
        guard client.updateContinuation != nil else {
            return XCTFail("First update did not reach its controlled suspension")
        }
        XCTAssertTrue(model.updatingUserIDs.contains("a"))
        await model.setDisabled(true, for: user)
        XCTAssertEqual(client.updates.count, 1, "the same account cannot queue contradictory changes")
        client.completePausedUpdate()
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertTrue(model.updatingUserIDs.isEmpty)
    }

    func testMissingTokenClearsPreviouslyLoadedAdministrativeData() async {
        let client = FakeAdminClient()
        client.pages = [AdminUserPage(users: [Self.view(id: "a")], nextCursor: nil)]
        var token: String? = "fixture"
        let model = AdminPanelModel(client: client, tokenProvider: { token })
        await model.load()
        token = nil
        await model.load()
        XCTAssertTrue(model.users.isEmpty)
        XCTAssertNil(model.stats)
        XCTAssertNotNil(model.message)
    }
}
