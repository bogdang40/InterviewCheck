import XCTest
@testable import memanager

/// The store, the gate, and the controller together: a license file on
/// disk unlocks the Mac with no server, survives a server sign out, and is
/// only a floor under a healthy server session.
@MainActor
final class OwnerLicenseGateTests: XCTestCase {
    private final class OfflineClient: AccessAPIClienting {
        var meResult: Result<AccessSnapshot, AccessAPIError> = .failure(.network("offline"))
        var onMe: (() -> Void)?
        func signup(email: String, password: String, adminSecret: String?) async throws -> SignedInResponse { throw AccessAPIError.network("offline") }
        func login(email: String, password: String) async throws -> SignedInResponse { throw AccessAPIError.network("offline") }
        func logout(token: String) async throws {}
        func me(token: String) async throws -> AccessSnapshot { onMe?(); return try meResult.get() }
        func plans() async throws -> BillingPlans { BillingPlans(configured: false, plans: []) }
        func checkoutURL(token: String, plan: String) async throws -> URL { URL(string: "https://example.test")! }
        func portalURL(token: String) async throws -> URL { URL(string: "https://example.test")! }
    }

    private let now = ISO8601DateParser.parse("2026-09-03T12:00:00Z")!
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("owner-license-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func licenseFile(_ envelope: OwnerLicenseEnvelope, name: String = "owner.license") throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try OwnerLicenseVerifierTests.data(envelope).write(to: url)
        return url
    }

    private func makeGate(store: OwnerLicenseStoring = MemoryOwnerLicenseStore(), device: String? = OwnerLicenseVerifierTests.device) -> OwnerLicenseGate {
        OwnerLicenseGate(
            store: store,
            verifier: OwnerLicenseVerifier(publicKeyBase64: OwnerLicenseVerifierTests.publicKey),
            deviceIdentity: FixedDeviceIdentity(id: device)
        )
    }

    private func serverSnapshot(active: Bool) -> AccessSnapshot {
        AccessSnapshot(
            user: AccountUser(id: "u1", email: "member@example.com", role: .user, disabled: false, createdAt: "2026-01-01T00:00:00Z", trialEndsAt: nil, complimentaryUntil: nil),
            entitlement: Entitlement(active: active, source: active ? .subscription : .none, expiresAt: nil, graceUntil: ISO8601DateParser.string(from: now.addingTimeInterval(86_400)), plan: "monthly", subscriptionStatus: active ? "active" : "canceled"),
            subscription: nil,
            serverTime: ISO8601DateParser.string(from: now)
        )
    }

    // MARK: - Store and gate

    func testFileStoreRoundTripsWithOwnerOnlyPermissions() throws {
        let store = FileOwnerLicenseStore(fileURL: tempDirectory.appendingPathComponent("nested/owner.license"))
        XCTAssertNil(store.load())
        let bytes = try OwnerLicenseVerifierTests.data(OwnerLicenseVerifierTests.open)
        try store.save(bytes)
        XCTAssertEqual(store.load(), bytes)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        try store.clear()
        XCTAssertNil(store.load())
        XCTAssertNoThrow(try store.clear(), "clearing twice is fine")
    }

    func testGateResolvesNoneInvalidAndValid() throws {
        let store = MemoryOwnerLicenseStore()
        XCTAssertEqual(makeGate(store: store).resolve(now: now), .none)

        store.data = try OwnerLicenseVerifierTests.data(OwnerLicenseVerifierTests.open)
        XCTAssertEqual(makeGate(store: store).resolve(now: now).license?.email, "owner@example.com")
        XCTAssertEqual(makeGate(store: store, device: nil).resolve(now: now), .invalid(.deviceUnavailable))
        XCTAssertEqual(makeGate(store: store, device: "FFFFFFFF-0000-0000-0000-000000000000").resolve(now: now), .invalid(.wrongDevice(licensed: OwnerLicenseVerifierTests.device, thisMac: "FFFFFFFF-0000-0000-0000-000000000000")))

        store.data = Data("garbage".utf8)
        XCTAssertEqual(makeGate(store: store).resolve(now: now), .invalid(.malformed))
    }

    func testInstallVerifiesBeforeStoringAndRemoveClears() throws {
        let store = MemoryOwnerLicenseStore()
        let gate = makeGate(store: store)
        let good = try licenseFile(OwnerLicenseVerifierTests.open)
        XCTAssertEqual(try gate.install(from: good, now: now).email, "owner@example.com")
        XCTAssertNotNil(store.data)

        let foreignGate = makeGate(store: store, device: "FFFFFFFF-0000-0000-0000-000000000000")
        XCTAssertThrowsError(try foreignGate.install(from: good, now: now))
        XCTAssertNotNil(store.data, "a refused file must not clear the stored one")

        try gate.remove()
        XCTAssertNil(store.data)
        XCTAssertEqual(gate.resolve(now: now), .none)
    }

    // MARK: - Controller

    func testLicenseUnlocksWithoutTokenAndSurvivesSignOut() async throws {
        let store = MemoryOwnerLicenseStore(data: try OwnerLicenseVerifierTests.data(OwnerLicenseVerifierTests.open))
        let client = OfflineClient()
        let controller = AccessController(client: client, tokenStore: MemoryAccessTokenStore(token: nil), cache: MemoryAccessSnapshotCache(cached: nil), ownerLicenseGate: makeGate(store: store), openURL: { _ in }, clock: { self.now })
        var granted = 0
        controller.onAccessGranted = { granted += 1 }

        await controller.evaluate()

        XCTAssertTrue(controller.isAllowed)
        XCTAssertTrue(controller.isUnlockedByOwnerLicense)
        XCTAssertTrue(controller.isAdmin)
        XCTAssertEqual(controller.ownerLicense.license?.email, "owner@example.com")
        XCTAssertEqual(controller.deviceID, OwnerLicenseVerifierTests.device)
        XCTAssertEqual(granted, 1)

        await controller.signOut()
        XCTAssertTrue(controller.isAllowed, "signing out of the server does not lock the owner's Mac")

        await controller.removeOwnerLicense()
        XCTAssertEqual(controller.state, .signedOut)
        XCTAssertEqual(controller.ownerLicense, .none)
    }

    func testLicenseIsAFloorUnderServerState() async throws {
        let store = MemoryOwnerLicenseStore(data: try OwnerLicenseVerifierTests.data(OwnerLicenseVerifierTests.open))
        let client = OfflineClient()
        client.meResult = .success(serverSnapshot(active: false))
        var current = now
        let controller = AccessController(client: client, tokenStore: MemoryAccessTokenStore(token: "t"), cache: MemoryAccessSnapshotCache(cached: nil), ownerLicenseGate: makeGate(store: store), openURL: { _ in }, clock: { current })

        await controller.evaluate()
        XCTAssertTrue(controller.isAllowed, "a paywalled server account cannot lock a licensed Mac")
        XCTAssertTrue(controller.isUnlockedByOwnerLicense)
        XCTAssertEqual(controller.snapshot?.user.email, "owner@example.com")
        XCTAssertEqual(controller.serverSnapshot?.user.email, "member@example.com", "billing must retain the signed in server account when a local license supplies access")
        XCTAssertEqual(controller.serverSnapshot?.user.isAdmin, false, "a local license does not grant the server account an administrator role")

        client.meResult = .success(serverSnapshot(active: true))
        await controller.evaluate()
        XCTAssertTrue(controller.isAllowed)
        XCTAssertFalse(controller.isUnlockedByOwnerLicense, "a healthy server session is the richer grant and wins")
        XCTAssertEqual(controller.snapshot?.user.email, "member@example.com")

        client.meResult = .failure(.network("down"))
        await controller.evaluate()
        XCTAssertTrue(controller.isAllowed)
        XCTAssertFalse(controller.isUnlockedByOwnerLicense, "inside the grace window the cached server grant still stands")

        current = now.addingTimeInterval(3 * 86_400)
        await controller.evaluate()
        XCTAssertTrue(controller.isAllowed, "past the grace window the license is still there")
        XCTAssertTrue(controller.isUnlockedByOwnerLicense)
        XCTAssertEqual(controller.serverSnapshot?.user.email, "member@example.com", "the last server identity remains distinct from the local access floor")

        await controller.signOut()
        XCTAssertNil(controller.serverSnapshot, "signing out must clear server identity even while local owner access remains")
        XCTAssertTrue(controller.isUnlockedByOwnerLicense)
    }

    func testLicensedMacIsAllowedBeforeTheServerRoundTrip() async throws {
        let store = MemoryOwnerLicenseStore(data: try OwnerLicenseVerifierTests.data(OwnerLicenseVerifierTests.open))
        let client = OfflineClient()
        let controller = AccessController(client: client, tokenStore: MemoryAccessTokenStore(token: "stale"), cache: MemoryAccessSnapshotCache(cached: nil), ownerLicenseGate: makeGate(store: store), openURL: { _ in }, clock: { self.now })
        var allowedWhenServerWasAsked: Bool?
        client.onMe = { allowedWhenServerWasAsked = controller.isAllowed }

        await controller.evaluate()

        XCTAssertEqual(allowedWhenServerWasAsked, true, "the gate is already down while the server request is in flight")
        XCTAssertTrue(controller.isAllowed)
        XCTAssertTrue(controller.isUnlockedByOwnerLicense)
    }

    func testDefaultGateIsHermeticUnderXCTest() {
        XCTAssertTrue(OwnerLicenseGate.defaultStore() is MemoryOwnerLicenseStore, "tests must never read the owner's real license file")
    }

    func testInstallFromTheUIRefusesAForeignFileWithAMessage() async throws {
        let store = MemoryOwnerLicenseStore()
        let controller = AccessController(client: OfflineClient(), tokenStore: MemoryAccessTokenStore(token: nil), cache: MemoryAccessSnapshotCache(cached: nil), ownerLicenseGate: makeGate(store: store, device: "FFFFFFFF-0000-0000-0000-000000000000"), openURL: { _ in }, clock: { self.now })
        await controller.evaluate()
        XCTAssertEqual(controller.state, .signedOut)

        await controller.installOwnerLicense(from: try licenseFile(OwnerLicenseVerifierTests.open))

        XCTAssertEqual(controller.state, .signedOut)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertNil(store.data)
    }
}
