import Foundation
import XCTest
@testable import memanager

/// Bounded waits make a regression fail instead of hanging the test runner.
final class BlockingAccessTokenStore: AccessTokenStoring {
    enum Operation { case read, save }
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private let blockedOperation: Operation?
    private let entered: XCTestExpectation?
    private let readError: Error?
    private var storedToken: String?
    private var mainThreadOperations = 0
    private var timedOut = false
    private var reads = 0

    init(token: String?, blocking: Operation? = nil, entered: XCTestExpectation? = nil, readError: Error? = nil) {
        self.storedToken = token
        self.blockedOperation = blocking
        self.entered = entered
        self.readError = readError
    }

    var token: String? { lock.withLock { storedToken } }
    var touchedMainThread: Bool { lock.withLock { mainThreadOperations > 0 } }
    var waitTimedOut: Bool { lock.withLock { timedOut } }
    var readCount: Int { lock.withLock { reads } }

    func unblock() { release.signal() }

    func load() -> String? { try? readForEvaluation() }

    func readForEvaluation() throws -> String? {
        recordThread()
        lock.withLock { reads += 1 }
        blockIfNeeded(.read)
        if let readError { throw readError }
        return token
    }

    func save(_ token: String) -> Bool {
        recordThread()
        blockIfNeeded(.save)
        lock.withLock { storedToken = token }
        return true
    }

    func clear() {
        recordThread()
        lock.withLock { storedToken = nil }
    }

    private func recordThread() {
        if Thread.isMainThread { lock.withLock { mainThreadOperations += 1 } }
    }

    private func blockIfNeeded(_ operation: Operation) {
        guard blockedOperation == operation else { return }
        entered?.fulfill()
        if release.wait(timeout: .now() + 2) == .timedOut {
            lock.withLock { timedOut = true }
        }
    }
}

final class PersistenceAccessClient: AccessAPIClienting {
    var meCalls = 0
    var loginResponse: SignedInResponse?
    var meOperation: (() async throws -> AccessSnapshot)?

    func signup(email: String, password: String, adminSecret: String?) async throws -> SignedInResponse {
        try await login(email: email, password: password)
    }
    func login(email: String, password: String) async throws -> SignedInResponse {
        guard let loginResponse else { throw AccessAPIError.network("fixture offline") }
        return loginResponse
    }
    func logout(token: String) async throws {}
    func me(token: String) async throws -> AccessSnapshot {
        meCalls += 1
        guard let meOperation else { throw AccessAPIError.network("fixture offline") }
        return try await meOperation()
    }
    func plans() async throws -> BillingPlans { BillingPlans(configured: false, plans: []) }
    func checkoutURL(token: String, plan: String) async throws -> URL { URL(string: "https://example.test")! }
    func portalURL(token: String) async throws -> URL { URL(string: "https://example.test")! }
}

enum AccessPersistenceFixtures {
    static let now = ISO8601DateParser.parse("2026-09-03T12:00:00Z")!

    static func snapshot(userID: String = "old") -> AccessSnapshot {
        AccessSnapshot(
            user: AccountUser(id: userID, email: "fixture@example.test", role: .user, disabled: false, createdAt: "2026-01-01T00:00:00Z", trialEndsAt: nil, complimentaryUntil: nil),
            entitlement: Entitlement(active: true, source: .subscription, expiresAt: nil, graceUntil: "2030-01-01T00:00:00Z", plan: nil, subscriptionStatus: nil),
            subscription: nil,
            serverTime: "2026-09-03T12:00:00Z"
        )
    }

    static func signedIn(userID: String = "new") -> SignedInResponse {
        let snapshot = snapshot(userID: userID)
        return SignedInResponse(token: "new-token", user: snapshot.user, entitlement: snapshot.entitlement, subscription: nil, serverTime: snapshot.serverTime)
    }

    @MainActor static func ownerGate(licensed: Bool = false) throws -> OwnerLicenseGate {
        let data = licensed ? try OwnerLicenseVerifierTests.data(OwnerLicenseVerifierTests.open) : nil
        return OwnerLicenseGate(
            store: MemoryOwnerLicenseStore(data: data),
            verifier: OwnerLicenseVerifier(publicKeyBase64: OwnerLicenseVerifierTests.publicKey),
            deviceIdentity: FixedDeviceIdentity(id: OwnerLicenseVerifierTests.device)
        )
    }
}

@MainActor
final class BoundedAccessResponse {
    private var continuation: CheckedContinuation<AccessSnapshot, Never>?
    private var timeout: Task<Void, Never>?
    private(set) var timedOut = false

    func wait(entered: XCTestExpectation) async -> AccessSnapshot {
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
        continuation?.resume(returning: AccessPersistenceFixtures.snapshot())
        continuation = nil
    }
}

final class RecordingAccessSnapshotCache: AccessSnapshotCaching {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private let saveEntered: XCTestExpectation?
    private var stored: CachedAccessSnapshot?
    private var operations: [String] = []
    private var usedMainThread = false
    private var timedOut = false

    init(blockingSave: XCTestExpectation? = nil) { saveEntered = blockingSave }
    var cached: CachedAccessSnapshot? { lock.withLock { stored } }
    var calls: [String] { lock.withLock { operations } }
    var touchedMainThread: Bool { lock.withLock { usedMainThread } }
    var waitTimedOut: Bool { lock.withLock { timedOut } }
    func unblock() { release.signal() }

    func load() -> CachedAccessSnapshot? { record("load"); return cached }
    func clear() { record("clear"); lock.withLock { stored = nil } }
    func save(_ cached: CachedAccessSnapshot) {
        record("save")
        if let saveEntered {
            saveEntered.fulfill()
            if release.wait(timeout: .now() + 2) == .timedOut { lock.withLock { timedOut = true } }
        }
        lock.withLock { stored = cached }
    }

    private func record(_ operation: String) {
        lock.withLock {
            operations.append(operation)
            usedMainThread = usedMainThread || Thread.isMainThread
        }
    }
}
