import Combine
import XCTest
@testable import memanager

@MainActor
final class AccessControllerWelcomeTests: XCTestCase {
    func testSignInPublishesOneWelcomeAfterCredentialsAreStored() async {
        let client = WelcomeAccessClient()
        let tokens = MemoryAccessTokenStore()
        let cache = MemoryAccessSnapshotCache(cached: nil)
        let access = WelcomeAccessFixtures.controller(client: client, tokens: tokens, cache: cache)
        var requests: [UUID] = []
        let observation = access.$welcomeRequestID.compactMap { $0 }.sink { request in
            requests.append(request)
            XCTAssertEqual(tokens.token, WelcomeAccessFixtures.response().token)
            XCTAssertEqual(cache.cached?.snapshot, WelcomeAccessFixtures.response().snapshot)
            XCTAssertTrue(access.isAllowed)
        }
        defer { observation.cancel() }

        await access.signIn(email: "welcome@example.test", password: "fixture-password")

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first, access.welcomeRequestID)
    }

    func testSignUpWelcomesAuthenticatedAccountWithoutBypassingPaywall() async throws {
        let client = WelcomeAccessClient()
        client.loginResult = .success(WelcomeAccessFixtures.response(active: false))
        let access = WelcomeAccessFixtures.controller(client: client)

        await access.signUp(email: "welcome@example.test", password: "fixture-password")

        _ = try XCTUnwrap(access.welcomeRequestID)
        XCTAssertFalse(access.isAllowed)
        guard case .paywall = access.state else { return XCTFail("expected account access to remain gated") }
    }

    func testFailedCredentialsNeverRequestWelcomeAndClearPreviousRequest() async {
        let client = WelcomeAccessClient()
        let access = WelcomeAccessFixtures.controller(client: client)
        await access.signIn(email: "welcome@example.test", password: "fixture-password")
        XCTAssertNotNil(access.welcomeRequestID)
        client.loginResult = .failure(.unauthenticated)

        await access.signIn(email: "welcome@example.test", password: "wrong-password")
        XCTAssertNil(access.welcomeRequestID)
        XCTAssertNotNil(access.errorMessage)
        await access.signUp(email: "welcome@example.test", password: "wrong-password")
        XCTAssertNil(access.welcomeRequestID)
        XCTAssertNotNil(access.errorMessage)
    }

    func testRefusedCredentialStorageDoesNotRequestWelcome() async {
        let access = WelcomeAccessFixtures.controller(client: WelcomeAccessClient(), tokens: WelcomeRefusingTokenStore())
        await access.signIn(email: "welcome@example.test", password: "fixture-password")
        XCTAssertNil(access.welcomeRequestID)
        XCTAssertNotNil(access.errorMessage)
        XCTAssertFalse(access.isAllowed)
    }

    func testRestorationAndRefreshNeverCreateOrReplayWelcome() async throws {
        let client = WelcomeAccessClient()
        let access = WelcomeAccessFixtures.controller(client: client, tokens: MemoryAccessTokenStore(token: "restored-token"))
        await access.evaluate()
        await access.refresh()
        XCTAssertTrue(access.isAllowed)
        XCTAssertNil(access.welcomeRequestID)

        await access.signIn(email: "welcome@example.test", password: "fixture-password")
        let request = try XCTUnwrap(access.welcomeRequestID)
        await access.refresh()
        XCTAssertEqual(access.welcomeRequestID, request)
        access.completeWelcome(requestID: request)
        await access.evaluate()
        await access.refresh()
        XCTAssertNil(access.welcomeRequestID)
    }

    func testOldCompletionCannotConsumeNewWelcome() async throws {
        let access = WelcomeAccessFixtures.controller(client: WelcomeAccessClient())
        await access.signIn(email: "welcome@example.test", password: "fixture-password")
        let previous = try XCTUnwrap(access.welcomeRequestID)
        await access.signIn(email: "welcome@example.test", password: "fixture-password")
        let current = try XCTUnwrap(access.welcomeRequestID)
        XCTAssertNotEqual(previous, current)

        access.completeWelcome(requestID: previous)
        XCTAssertEqual(access.welcomeRequestID, current)
        access.completeWelcome(requestID: current)
        access.completeWelcome(requestID: current)
        XCTAssertNil(access.welcomeRequestID)
        XCTAssertTrue(access.isAllowed)
    }

    func testSignOutClearsWelcomeAndLateCompletionIsHarmless() async throws {
        let access = WelcomeAccessFixtures.controller(client: WelcomeAccessClient())
        await access.signIn(email: "welcome@example.test", password: "fixture-password")
        let request = try XCTUnwrap(access.welcomeRequestID)
        await access.signOut()
        access.completeWelcome(requestID: request)
        XCTAssertNil(access.welcomeRequestID)
        XCTAssertEqual(access.state, .signedOut)
    }

    func testInvalidatedSessionClearsPendingWelcome() async {
        let client = WelcomeAccessClient()
        let access = WelcomeAccessFixtures.controller(client: client)
        await access.signIn(email: "welcome@example.test", password: "fixture-password")
        XCTAssertNotNil(access.welcomeRequestID)
        client.meResult = .failure(.unauthenticated)
        await access.evaluate()
        XCTAssertNil(access.welcomeRequestID)
        XCTAssertEqual(access.state, .signedOut)
    }

    func testSignOutDiscardsWelcomeFromInFlightSignIn() async {
        let entered = expectation(description: "login suspended")
        let pending = SuspendedWelcomeLogin()
        let client = WelcomeAccessClient()
        client.loginOperation = { await pending.wait(entered: entered) }
        let tokens = MemoryAccessTokenStore()
        let access = WelcomeAccessFixtures.controller(client: client, tokens: tokens)
        let signIn = Task { await access.signIn(email: "welcome@example.test", password: "fixture-password") }
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertNil(access.welcomeRequestID)

        await access.signOut()
        pending.finish()
        await signIn.value
        XCTAssertFalse(pending.timedOut)
        XCTAssertNil(tokens.token)
        XCTAssertNil(access.welcomeRequestID)
        XCTAssertEqual(access.state, .signedOut)
    }

    func testOwnerLicenseInstallationDoesNotRequestWelcome() async {
        let access = WelcomeAccessFixtures.controller(client: WelcomeAccessClient())
        await access.installOwnerLicense(from: URL(fileURLWithPath: "/unused-owner-fixture"))
        XCTAssertTrue(access.isUnlockedByOwnerLicense)
        XCTAssertNil(access.welcomeRequestID)
        await access.refresh()
        XCTAssertNil(access.welcomeRequestID)
    }
}
