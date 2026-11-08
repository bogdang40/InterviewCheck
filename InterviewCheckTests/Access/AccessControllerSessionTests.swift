import XCTest
@testable import InterviewCheck

/// Session lifecycle edge cases: an evaluation racing a sign out, and a
/// Keychain that refuses to store the token.
@MainActor
final class AccessControllerSessionTests: XCTestCase {
    private final class SlowClient: AccessAPIClienting {
        var meResult: Result<AccessSnapshot, AccessAPIError> = .failure(.network("offline"))
        var loginResult: Result<SignedInResponse, AccessAPIError> = .failure(.network("offline"))
        var meDelayNanoseconds: UInt64 = 0
        var logoutCalls = 0

        func signup(email: String, password: String, adminSecret: String?) async throws -> SignedInResponse { try loginResult.get() }
        func login(email: String, password: String) async throws -> SignedInResponse { try loginResult.get() }
        func logout(token: String) async throws { logoutCalls += 1 }
        func me(token: String) async throws -> AccessSnapshot {
            if meDelayNanoseconds > 0 { try? await Task.sleep(nanoseconds: meDelayNanoseconds) }
            return try meResult.get()
        }
        func plans() async throws -> BillingPlans { BillingPlans(configured: true, plans: ["monthly"]) }
        func checkoutURL(token: String, plan: String) async throws -> URL { URL(string: "https://example.test")! }
        func portalURL(token: String) async throws -> URL { URL(string: "https://example.test")! }
    }

    /// A Keychain stand in whose writes fail.
    private final class RefusingTokenStore: AccessTokenStoring {
        func load() -> String? { nil }
        @discardableResult func save(_ token: String) -> Bool { false }
        func clear() {}
    }

    private let now = Date(timeIntervalSince1970: 1_756_800_000)

    private func snapshot(active: Bool) -> AccessSnapshot {
        AccessSnapshot(
            user: AccountUser(id: "u1", email: "a@b.c", role: .user, disabled: false, createdAt: "2026-01-01T00:00:00Z", trialEndsAt: nil, complimentaryUntil: nil),
            entitlement: Entitlement(active: active, source: active ? .subscription : .none, expiresAt: nil, graceUntil: ISO8601DateParser.string(from: now.addingTimeInterval(86_400)), plan: "monthly", subscriptionStatus: active ? "active" : "canceled"),
            subscription: nil,
            serverTime: ISO8601DateParser.string(from: now)
        )
    }

    func testSignOutDuringEvaluateDiscardsTheLateResult() async {
        let client = SlowClient()
        client.meResult = .success(snapshot(active: false))
        client.meDelayNanoseconds = 50_000_000
        let tokens = MemoryAccessTokenStore(token: "mm_old")
        let cache = MemoryAccessSnapshotCache(cached: nil)
        let controller = AccessController(client: client, tokenStore: tokens, cache: cache, openURL: { _ in }, clock: { self.now })

        let evaluation = Task { await controller.evaluate() }
        try? await Task.sleep(nanoseconds: 5_000_000)
        await controller.signOut()
        await evaluation.value

        XCTAssertEqual(controller.state, .signedOut, "the paywall answer that arrived after sign out must not win")
        XCTAssertNil(tokens.token)
        XCTAssertNil(cache.cached, "the late snapshot must not repopulate the cleared cache")
    }

    func testSignOutDuringFailingEvaluateStaysSignedOut() async {
        let client = SlowClient()
        client.meResult = .failure(.network("cancelled"))
        client.meDelayNanoseconds = 50_000_000
        let tokens = MemoryAccessTokenStore(token: "mm_old")
        let controller = AccessController(client: client, tokenStore: tokens, cache: MemoryAccessSnapshotCache(cached: nil), openURL: { _ in }, clock: { self.now })

        let evaluation = Task { await controller.evaluate() }
        try? await Task.sleep(nanoseconds: 5_000_000)
        await controller.signOut()
        await evaluation.value

        XCTAssertEqual(controller.state, .signedOut, "a failure from the cancelled request must not show the unreachable screen")
    }

    func testKeychainRefusalSurfacesInsteadOfGrantingAccessForOneRun() async {
        let client = SlowClient()
        let active = snapshot(active: true)
        client.loginResult = .success(SignedInResponse(token: "mm_new", user: active.user, entitlement: active.entitlement, subscription: nil, serverTime: active.serverTime))
        let cache = MemoryAccessSnapshotCache(cached: nil)
        let controller = AccessController(client: client, tokenStore: RefusingTokenStore(), cache: cache, openURL: { _ in }, clock: { self.now })
        await controller.evaluate()

        await controller.signIn(email: "a@b.c", password: "long-password!")

        XCTAssertFalse(controller.isAllowed)
        XCTAssertEqual(controller.state, .signedOut)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertNil(cache.cached)
    }

    func testRefreshOnThePaywallLoadsPlansWhenMissing() async {
        let client = SlowClient()
        client.meResult = .success(snapshot(active: false))
        let controller = AccessController(client: client, tokenStore: MemoryAccessTokenStore(token: "mm_old"), cache: MemoryAccessSnapshotCache(cached: nil), openURL: { _ in }, clock: { self.now })

        XCTAssertNil(controller.plans)
        await controller.refresh()

        guard case .paywall = controller.state else { return XCTFail("expected the paywall") }
        XCTAssertEqual(controller.plans?.plans, ["monthly"])
    }
}
