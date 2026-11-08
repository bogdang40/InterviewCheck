import Combine
import Security
import XCTest
@testable import InterviewCheck

@MainActor
final class AccessControllerPersistenceTests: XCTestCase {
    private func controller(tokens: AccessTokenStoring, cache: AccessSnapshotCaching = MemoryAccessSnapshotCache(), client: PersistenceAccessClient = PersistenceAccessClient(), licensed: Bool = false) throws -> AccessController {
        AccessController(client: client, tokenStore: tokens, cache: cache, ownerLicenseGate: try AccessPersistenceFixtures.ownerGate(licensed: licensed), openURL: { _ in }, clock: { AccessPersistenceFixtures.now })
    }

    func testBlockedTokenReadKeepsMainActorResponsiveAndOwnerAllowed() async throws {
        let entered = expectation(description: "token read suspended")
        let tokens = BlockingAccessTokenStore(token: "old-token", blocking: .read, entered: entered)
        let access = try controller(tokens: tokens, licensed: true)
        let evaluation = Task { await access.evaluate() }
        await fulfillment(of: [entered], timeout: 1)

        XCTAssertTrue(access.isUnlockedByOwnerLicense)
        XCTAssertNil(access.token, "UI reads must only consult loaded memory")
        XCTAssertEqual(tokens.readCount, 1)
        XCTAssertFalse(tokens.touchedMainThread)
        tokens.unblock()
        await evaluation.value
        XCTAssertFalse(tokens.waitTimedOut)
        XCTAssertEqual(access.token, "old-token")
    }

    func testSignOutDuringBlockedReadDiscardsStoredSession() async throws {
        let entered = expectation(description: "token read suspended")
        let tokens = BlockingAccessTokenStore(token: "old-token", blocking: .read, entered: entered)
        let cache = MemoryAccessSnapshotCache(cached: .init(snapshot: AccessPersistenceFixtures.snapshot(), fetchedAt: AccessPersistenceFixtures.now))
        let client = PersistenceAccessClient()
        let access = try controller(tokens: tokens, cache: cache, client: client)
        let evaluation = Task { await access.evaluate() }
        await fulfillment(of: [entered], timeout: 1)

        let signedOut = expectation(description: "UI signed out before storage resumed")
        let observation = access.$state.dropFirst().filter { $0 == .signedOut }.sink { _ in signedOut.fulfill() }
        defer { observation.cancel() }
        let signOut = Task { await access.signOut() }
        await fulfillment(of: [signedOut], timeout: 1)
        XCTAssertEqual(access.state, .signedOut)
        XCTAssertNil(access.token)
        tokens.unblock()
        await signOut.value
        await evaluation.value

        XCTAssertEqual(access.state, .signedOut)
        XCTAssertNil(access.serverSnapshot)
        XCTAssertNil(cache.cached)
        XCTAssertNil(tokens.token)
        XCTAssertEqual(client.meCalls, 0)
        XCTAssertFalse(tokens.touchedMainThread)
        XCTAssertFalse(tokens.waitTimedOut)
    }

    func testSignOutDuringBlockedTokenSaveCannotRestoreAccountOrCache() async throws {
        let entered = expectation(description: "token save suspended")
        let tokens = BlockingAccessTokenStore(token: nil, blocking: .save, entered: entered)
        let cache = MemoryAccessSnapshotCache()
        let client = PersistenceAccessClient()
        client.loginResponse = AccessPersistenceFixtures.signedIn()
        let access = try controller(tokens: tokens, cache: cache, client: client)
        let signIn = Task { await access.signIn(email: "fixture@example.test", password: "fixture-password") }
        await fulfillment(of: [entered], timeout: 1)

        XCTAssertNil(access.welcomeRequestID)
        let signedOut = expectation(description: "UI signed out before token save resumed")
        let observation = access.$state.dropFirst().filter { $0 == .signedOut }.sink { _ in signedOut.fulfill() }
        defer { observation.cancel() }
        let signOut = Task { await access.signOut() }
        await fulfillment(of: [signedOut], timeout: 1)
        XCTAssertEqual(access.state, .signedOut)
        tokens.unblock()
        await signIn.value
        await signOut.value

        XCTAssertEqual(access.state, .signedOut)
        XCTAssertNil(access.welcomeRequestID)
        XCTAssertNil(access.token)
        XCTAssertNil(access.serverSnapshot)
        XCTAssertNil(cache.cached)
        XCTAssertNil(tokens.token)
        XCTAssertFalse(tokens.touchedMainThread)
        XCTAssertFalse(tokens.waitTimedOut)
    }

    func testWelcomeWaitsUntilSnapshotStorageFinishes() async throws {
        let entered = expectation(description: "credential snapshot save suspended")
        let cache = RecordingAccessSnapshotCache(blockingSave: entered)
        let client = PersistenceAccessClient()
        client.loginResponse = AccessPersistenceFixtures.signedIn()
        let access = try controller(tokens: MemoryAccessTokenStore(), cache: cache, client: client)
        let signIn = Task { await access.signIn(email: "fixture@example.test", password: "fixture-password") }
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertNil(access.welcomeRequestID)
        XCTAssertFalse(access.isAllowed)

        cache.unblock()
        await signIn.value

        XCTAssertNotNil(access.welcomeRequestID)
        XCTAssertTrue(access.isAllowed)
        XCTAssertFalse(cache.waitTimedOut)
    }

    func testInaccessibleTokenPreservesCredentialsAndCache() async throws {
        let tokens = BlockingAccessTokenStore(token: "retained-token", readError: KeychainReadError(status: errSecInteractionNotAllowed))
        let cached = CachedAccessSnapshot(snapshot: AccessPersistenceFixtures.snapshot(), fetchedAt: AccessPersistenceFixtures.now)
        let cache = MemoryAccessSnapshotCache(cached: cached)
        let client = PersistenceAccessClient()
        let access = try controller(tokens: tokens, cache: cache, client: client)
        await access.evaluate()

        guard case .unreachable = access.state else { return XCTFail("expected recoverable Keychain failure") }
        XCTAssertEqual(tokens.token, "retained-token")
        XCTAssertEqual(cache.cached, cached)
        XCTAssertEqual(client.meCalls, 0)
        XCTAssertFalse(tokens.touchedMainThread)
    }

    func testCacheIOStaysOffMainActorAndLateSaveCannotRestoreSignedOutState() async throws {
        let entered = expectation(description: "snapshot save suspended")
        let cache = RecordingAccessSnapshotCache(blockingSave: entered)
        let client = PersistenceAccessClient()
        client.meOperation = { AccessPersistenceFixtures.snapshot() }
        let access = try controller(tokens: MemoryAccessTokenStore(token: "old-token"), cache: cache, client: client)
        let evaluation = Task { await access.evaluate() }
        await fulfillment(of: [entered], timeout: 1)

        let signedOut = expectation(description: "UI signed out before snapshot save resumed")
        let observation = access.$state.dropFirst().filter { $0 == .signedOut }.sink { _ in signedOut.fulfill() }
        defer { observation.cancel() }
        let signOut = Task { await access.signOut() }
        await fulfillment(of: [signedOut], timeout: 1)
        XCTAssertEqual(access.state, .signedOut)
        cache.unblock()
        await evaluation.value
        await signOut.value

        XCTAssertEqual(access.state, .signedOut)
        XCTAssertNil(access.serverSnapshot)
        XCTAssertNil(cache.cached)
        XCTAssertEqual(cache.calls, ["load", "save", "clear"])
        XCTAssertFalse(cache.touchedMainThread)
        XCTAssertFalse(cache.waitTimedOut)
    }

    func testLateEvaluationCannotReplaceNewlySignedInAccount() async throws {
        let entered = expectation(description: "old account request suspended")
        let tokens = MemoryAccessTokenStore(token: "old-token")
        let cache = MemoryAccessSnapshotCache()
        let client = PersistenceAccessClient()
        let oldRequest = BoundedAccessResponse()
        client.meOperation = { await oldRequest.wait(entered: entered) }
        client.loginResponse = AccessPersistenceFixtures.signedIn()
        let access = try controller(tokens: tokens, cache: cache, client: client)
        let evaluation = Task { await access.evaluate() }
        await fulfillment(of: [entered], timeout: 1)

        await access.signIn(email: "fixture@example.test", password: "fixture-password")
        oldRequest.finish()
        await evaluation.value

        XCTAssertFalse(oldRequest.timedOut)
        XCTAssertEqual(access.token, "new-token")
        XCTAssertEqual(access.serverSnapshot?.user.id, "new")
        XCTAssertEqual(cache.cached?.snapshot.user.id, "new")
    }
}
