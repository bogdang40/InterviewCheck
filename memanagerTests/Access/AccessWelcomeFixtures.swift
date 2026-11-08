import Foundation
import XCTest
@testable import memanager

enum WelcomeAccessFixtures {
    static let now = Date(timeIntervalSince1970: 1_756_800_000)

    static func response(active: Bool = true) -> SignedInResponse {
        SignedInResponse(
            token: "welcome-test-token",
            user: AccountUser(id: "welcome-user", email: "welcome@example.test", role: .user, disabled: false,
                             createdAt: "2026-01-01T00:00:00Z", trialEndsAt: nil, complimentaryUntil: nil),
            entitlement: Entitlement(active: active, source: active ? .subscription : .none, expiresAt: nil,
                                     graceUntil: "2030-01-01T00:00:00Z", plan: nil, subscriptionStatus: nil),
            subscription: nil, serverTime: "2026-09-07T12:00:00Z"
        )
    }

    @MainActor static func controller(
        client: WelcomeAccessClient,
        tokens: AccessTokenStoring = MemoryAccessTokenStore(),
        cache: AccessSnapshotCaching = MemoryAccessSnapshotCache(cached: nil),
        owner: WelcomeOwnerLicenseGate? = nil
    ) -> AccessController {
        AccessController(client: client, tokenStore: tokens, cache: cache,
                         ownerLicenseGate: owner ?? WelcomeOwnerLicenseGate(), openURL: { _ in }, clock: { now })
    }
}

@MainActor
final class WelcomeAccessClient: AccessAPIClienting {
    var loginResult: Result<SignedInResponse, AccessAPIError> = .success(WelcomeAccessFixtures.response())
    var meResult: Result<AccessSnapshot, AccessAPIError> = .success(WelcomeAccessFixtures.response().snapshot)
    var loginOperation: (() async -> SignedInResponse)?

    func signup(email: String, password: String, adminSecret: String?) async throws -> SignedInResponse {
        try await login(email: email, password: password)
    }
    func login(email: String, password: String) async throws -> SignedInResponse {
        if let loginOperation { return await loginOperation() }
        return try loginResult.get()
    }
    func logout(token: String) async throws {}
    func me(token: String) async throws -> AccessSnapshot { try meResult.get() }
    func plans() async throws -> BillingPlans { BillingPlans(configured: false, plans: []) }
    func checkoutURL(token: String, plan: String) async throws -> URL { URL(string: "https://example.test")! }
    func portalURL(token: String) async throws -> URL { URL(string: "https://example.test")! }
}

final class WelcomeRefusingTokenStore: AccessTokenStoring {
    func load() -> String? { nil }
    func save(_ token: String) -> Bool { false }
    func clear() {}
}

@MainActor
final class WelcomeOwnerLicenseGate: OwnerLicenseGating {
    let deviceID: String? = "welcome-test-device"
    let location = "memory"
    private var license: OwnerLicense?

    func resolve(now: Date) -> OwnerLicenseResolution { license.map(OwnerLicenseResolution.valid) ?? .none }
    func install(from fileURL: URL, now: Date) throws -> OwnerLicense {
        let installed = OwnerLicense(version: 1, email: "owner@example.test", deviceID: "welcome-test-device",
                                     issuedAt: "2026-01-01T00:00:00Z", expiresAt: nil, note: nil)
        license = installed
        return installed
    }
    func remove() throws { license = nil }
}

/// A bounded network suspension keeps a regression from hanging the test host.
@MainActor
final class SuspendedWelcomeLogin {
    private var continuation: CheckedContinuation<SignedInResponse, Never>?
    private var timeout: Task<Void, Never>?
    private(set) var timedOut = false

    func wait(entered: XCTestExpectation) async -> SignedInResponse {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            timeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                self?.timedOut = true
                self?.finish()
            }
            entered.fulfill()
        }
    }

    func finish() {
        timeout?.cancel()
        timeout = nil
        continuation?.resume(returning: WelcomeAccessFixtures.response())
        continuation = nil
    }
}
