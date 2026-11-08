import XCTest
@testable import memanager

@MainActor
final class AccessControllerTests: XCTestCase {
    private final class FakeClient: AccessAPIClienting {
        var meResult: Result<AccessSnapshot, AccessAPIError> = .failure(.network("offline"))
        var loginResult: Result<SignedInResponse, AccessAPIError> = .failure(.server(status: 401, code: "invalid_credentials", message: "nope"))
        var checkoutURL = URL(string: "https://checkout.stripe.test/cs")!
        var logoutCalls = 0
        var meCalls = 0
        var plansResult: Result<BillingPlans, AccessAPIError> = .success(BillingPlans(configured: true, plans: ["monthly", "annual"]))

        var lastAdminSecret: String?
        func signup(email: String, password: String, adminSecret: String?) async throws -> SignedInResponse {
            lastAdminSecret = adminSecret
            return try loginResult.get()
        }
        func login(email: String, password: String) async throws -> SignedInResponse { try loginResult.get() }
        func logout(token: String) async throws { logoutCalls += 1 }
        func me(token: String) async throws -> AccessSnapshot { meCalls += 1; return try meResult.get() }
        func plans() async throws -> BillingPlans { try plansResult.get() }
        func checkoutURL(token: String, plan: String) async throws -> URL { checkoutURL }
        func portalURL(token: String) async throws -> URL { checkoutURL }
    }

    private let now = Date(timeIntervalSince1970: 1_756_800_000)

    func testPlanLoadingFailureIsRecoverableAndDistinctFromLoading() async {
        let client = FakeClient()
        client.plansResult = .failure(.network("Plan service timed out"))
        let (controller, _, _) = makeController(client: client, token: "fixture")
        await controller.loadPlans()
        XCTAssertFalse(controller.isLoadingPlans)
        XCTAssertNil(controller.plans)
        XCTAssertNotNil(controller.plansError)
        client.plansResult = .success(BillingPlans(configured: true, plans: ["monthly"]))
        await controller.loadPlans()
        XCTAssertEqual(controller.plans?.plans, ["monthly"])
        XCTAssertNil(controller.plansError)
        await controller.signOut()
        XCTAssertNil(controller.plans, "plans from a previous account/server should not remain in the next sign-in flow")
    }

    private func snapshot(active: Bool) -> AccessSnapshot {
        AccessSnapshot(
            user: AccountUser(id: "u1", email: "a@b.c", role: .user, disabled: false, createdAt: "2026-01-01T00:00:00Z", trialEndsAt: nil, complimentaryUntil: nil),
            entitlement: Entitlement(active: active, source: active ? .subscription : .none, expiresAt: nil, graceUntil: ISO8601DateParser.string(from: now.addingTimeInterval(86_400)), plan: "monthly", subscriptionStatus: active ? "active" : "canceled"),
            subscription: nil,
            serverTime: ISO8601DateParser.string(from: now)
        )
    }

    private func makeController(client: FakeClient, token: String?, cached: CachedAccessSnapshot? = nil, opened: (@MainActor (URL) -> Void)? = nil) -> (AccessController, MemoryAccessTokenStore, MemoryAccessSnapshotCache) {
        let tokens = MemoryAccessTokenStore(token: token)
        let cache = MemoryAccessSnapshotCache(cached: cached)
        // No owner license in play: an empty in memory store and no device id.
        let gate = OwnerLicenseGate(store: MemoryOwnerLicenseStore(), verifier: OwnerLicenseVerifier(publicKeyBase64: OwnerLicenseVerifierTests.publicKey), deviceIdentity: FixedDeviceIdentity(id: nil))
        let controller = AccessController(client: client, tokenStore: tokens, cache: cache, ownerLicenseGate: gate, openURL: { url in opened?(url) }, clock: { self.now })
        return (controller, tokens, cache)
    }

    func testEvaluateWithoutTokenIsSignedOutAndSkipsNetwork() async {
        let client = FakeClient()
        let (controller, _, _) = makeController(client: client, token: nil)
        await controller.evaluate()
        XCTAssertEqual(controller.state, .signedOut)
        XCTAssertEqual(client.meCalls, 0)
    }

    func testSignInStoresTokenCachesSnapshotAndFiresGranted() async {
        let client = FakeClient()
        let active = snapshot(active: true)
        client.loginResult = .success(SignedInResponse(token: "mm_new", user: active.user, entitlement: active.entitlement, subscription: nil, serverTime: active.serverTime))
        let (controller, tokens, cache) = makeController(client: client, token: nil)
        var granted = 0
        controller.onAccessGranted = { granted += 1 }

        await controller.signIn(email: "a@b.c", password: "long-password!")

        XCTAssertEqual(tokens.token, "mm_new")
        XCTAssertEqual(cache.cached?.snapshot, active)
        XCTAssertTrue(controller.isAllowed)
        XCTAssertEqual(granted, 1)
        XCTAssertNil(controller.errorMessage)
    }

    func testFailedSignInSurfacesServerMessage() async {
        let client = FakeClient()
        let (controller, tokens, _) = makeController(client: client, token: nil)
        await controller.evaluate()
        await controller.signIn(email: "a@b.c", password: "wrong-password!")
        XCTAssertEqual(controller.errorMessage, "nope")
        XCTAssertNil(tokens.token)
        XCTAssertEqual(controller.state, .signedOut)
    }

    func testRevokedEntitlementFiresRevokedAndPaywalls() async {
        let client = FakeClient()
        client.meResult = .success(snapshot(active: true))
        let (controller, _, _) = makeController(client: client, token: "mm_t")
        await controller.evaluate()
        XCTAssertTrue(controller.isAllowed)

        var revoked = 0
        controller.onAccessRevoked = { revoked += 1 }
        client.meResult = .success(snapshot(active: false))
        await controller.evaluate()
        XCTAssertEqual(revoked, 1)
        if case .paywall = controller.state {} else { XCTFail("expected paywall, got \(controller.state)") }
    }

    func testOfflineFallsBackToCachedGrant() async {
        let client = FakeClient()
        let cached = CachedAccessSnapshot(snapshot: snapshot(active: true), fetchedAt: now.addingTimeInterval(-3_600))
        let (controller, _, _) = makeController(client: client, token: "mm_t", cached: cached)
        await controller.evaluate()
        XCTAssertEqual(controller.state, .allowed(cached.snapshot, offline: true))
    }

    func testInvalidSessionClearsTokenAndCache() async {
        let client = FakeClient()
        client.meResult = .failure(.unauthenticated)
        let cached = CachedAccessSnapshot(snapshot: snapshot(active: true), fetchedAt: now)
        let (controller, tokens, cache) = makeController(client: client, token: "mm_t", cached: cached)
        await controller.evaluate()
        XCTAssertEqual(controller.state, .signedOut)
        XCTAssertNil(tokens.token)
        XCTAssertNil(cache.cached)
    }

    func testSignUpForwardsTheAdminSecret() async {
        let client = FakeClient()
        let active = snapshot(active: true)
        client.loginResult = .success(SignedInResponse(token: "mm_new", user: active.user, entitlement: active.entitlement, subscription: nil, serverTime: active.serverTime))
        let (controller, _, _) = makeController(client: client, token: nil)
        await controller.signUp(email: "a@b.c", password: "long-password!", adminSecret: "bootstrap")
        XCTAssertEqual(client.lastAdminSecret, "bootstrap")
        XCTAssertTrue(controller.isAllowed)
    }

    func testSignOutCallsLogoutAndForgetsEverything() async {
        let client = FakeClient()
        client.meResult = .success(snapshot(active: true))
        let (controller, tokens, cache) = makeController(client: client, token: "mm_t")
        await controller.evaluate()
        await controller.signOut()
        XCTAssertEqual(client.logoutCalls, 1)
        XCTAssertNil(tokens.token)
        XCTAssertNil(cache.cached)
        XCTAssertEqual(controller.state, .signedOut)
    }

    func testCheckoutOpensStripeAndStartsWaiting() async {
        let client = FakeClient()
        client.meResult = .success(snapshot(active: false))
        var opened: [URL] = []
        let (controller, _, _) = makeController(client: client, token: "mm_t", opened: { opened.append($0) })
        await controller.evaluate()
        await controller.startCheckout(plan: "annual")
        XCTAssertEqual(opened, [client.checkoutURL])
        XCTAssertTrue(controller.isAwaitingCheckout)
        XCTAssertTrue(controller.handleDeepLink(URL(string: "memanager://billing/cancel")!))
        XCTAssertFalse(controller.isAwaitingCheckout)
        XCTAssertFalse(controller.handleDeepLink(URL(string: "memanager://nothing")!))
    }
}
