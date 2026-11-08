import AppKit
import Combine
import Foundation

/// Owns sign in state and entitlement. The overlay displays its state while
/// storage and network work run asynchronously. SessionController consults
/// access before spending model calls.
@MainActor
final class AccessController: ObservableObject {
    static let shared = AccessController()

    @Published private(set) var state: AccessGateState = .checking
    @Published private(set) var isBusy = false
    @Published private(set) var plans: BillingPlans?
    @Published private(set) var isLoadingPlans = false
    @Published private(set) var plansError: String?
    @Published private(set) var isAwaitingCheckout = false
    @Published private(set) var ownerLicense: OwnerLicenseResolution = .none
    /// The real server account remains separate when a local license supplies access.
    @Published private(set) var serverSnapshot: AccessSnapshot?
    /// Ephemeral presentation request from a completed explicit credential flow.
    @Published private(set) var welcomeRequestID: UUID?
    @Published var errorMessage: String?

    var onAccessGranted: (() -> Void)?
    var onAccessRevoked: (() -> Void)?

    private let client: AccessAPIClienting
    private let persistence: AccessPersistence
    @Published private var loadedToken: String?
    private let ownerLicenseGate: OwnerLicenseGating
    private let openURL: (URL) -> Void
    private let clock: () -> Date
    private let scheduler = AccessVerificationScheduler()
    /// Bumped whenever the session is forgotten. An evaluation that started
    /// under an older generation discards its result instead of reviving a
    /// cache and a state the user just signed out of.
    private var sessionGeneration = 0
    private var evaluationGeneration = 0

    init(
        client: AccessAPIClienting = AccessAPIClient(),
        tokenStore: AccessTokenStoring = KeychainAccessTokenStore(),
        cache: AccessSnapshotCaching = UserDefaultsAccessSnapshotCache(),
        ownerLicenseGate: OwnerLicenseGating = OwnerLicenseGate(),
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        clock: @escaping () -> Date = { Date() }
    ) {
        self.client = client
        self.persistence = AccessPersistence(tokens: tokenStore, cache: cache)
        self.ownerLicenseGate = ownerLicenseGate
        self.openURL = openURL
        self.clock = clock
    }

    // MARK: - Reads

    var isAllowed: Bool { state.isAllowed }
    var snapshot: AccessSnapshot? { state.snapshot }
    var isAdmin: Bool { snapshot?.user.isAdmin ?? false }
    var token: String? { loadedToken }
    /// True when the grant in force is the owner license rather than a
    /// server account.
    var isUnlockedByOwnerLicense: Bool { snapshot?.user.isOwnerLicenseAccount ?? false }
    var deviceID: String? { ownerLicenseGate.deviceID }
    var ownerLicenseLocation: String { ownerLicenseGate.location }

    // MARK: - Evaluation

    /// Fetches /me (when a token exists) and recomputes the gate state. The
    /// owner license is re-read every time so a file dropped next to the
    /// app takes effect on the next check.
    func evaluate() async {
        let generation = sessionGeneration
        evaluationGeneration += 1
        let evaluation = evaluationGeneration
        ownerLicense = ownerLicenseGate.resolve(now: clock())
        // A local license settles access before any Keychain or server wait.
        if let license = ownerLicense.license, !state.isAllowed {
            apply(.allowed(license.accessSnapshot(now: clock()), offline: false))
        }
        let stored = await persistence.readSession()
        guard generation == sessionGeneration, evaluation == evaluationGeneration else { return }
        let session: AccessPersistence.Session
        switch stored {
        case .success(let value): session = value
        case .failure(let error):
            // Inaccessible credentials still exist. Keep them and the cache
            // intact so unlocking the Keychain and retrying can recover.
            let message = "The saved account could not be read from the Keychain. \(error.localizedDescription)"
            if let license = ownerLicense.license {
                apply(.allowed(license.accessSnapshot(now: clock()), offline: false))
            } else {
                apply(.unreachable(message: message))
            }
            return
        }
        loadedToken = session.token
        serverSnapshot = session.cached?.snapshot
        var fresh: Result<AccessSnapshot, AccessAPIError>?
        if let token = session.token {
            do {
                let snapshot = try await client.me(token: token)
                guard generation == sessionGeneration, evaluation == evaluationGeneration else { return }
                await persistence.saveSnapshot(CachedAccessSnapshot(snapshot: snapshot, fetchedAt: clock()))
                guard generation == sessionGeneration, evaluation == evaluationGeneration else { return }
                serverSnapshot = snapshot
                fresh = .success(snapshot)
            } catch {
                guard generation == sessionGeneration, evaluation == evaluationGeneration else { return }
                let failure = (error as? AccessAPIError) ?? .network(error.localizedDescription)
                if failure.invalidatesSession {
                    forgetSession()
                    apply(AccessGatePolicy.decide(.init(hasToken: false, fresh: nil, cached: nil, now: clock(), ownerLicense: ownerLicense.license)))
                    await persistence.clear()
                    return
                }
                fresh = .failure(failure)
            }
        }
        apply(AccessGatePolicy.decide(.init(hasToken: session.token != nil, fresh: fresh, cached: session.cached, now: clock(), ownerLicense: ownerLicense.license)))
    }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await evaluate()
        if plans == nil, case .paywall = state {
            await loadPlans()
        }
    }

    // MARK: - Credentials

    func signIn(email: String, password: String) async {
        await runCredentialFlow { try await self.client.login(email: email, password: password) }
    }

    func signUp(email: String, password: String, adminSecret: String? = nil) async {
        await runCredentialFlow { try await self.client.signup(email: email, password: password, adminSecret: adminSecret) }
    }

    /// A previous animation must not dismiss a newer account's welcome.
    func completeWelcome(requestID: UUID) {
        guard welcomeRequestID == requestID else { return }
        welcomeRequestID = nil
    }

    private func runCredentialFlow(_ operation: @escaping () async throws -> SignedInResponse) async {
        guard !isBusy else { return }
        sessionGeneration += 1
        var generation = sessionGeneration
        isBusy = true
        errorMessage = nil
        welcomeRequestID = nil
        defer { isBusy = false }
        do {
            let response = try await operation()
            guard generation == sessionGeneration else { return }
            // Also invalidate evaluations started while login was in flight.
            sessionGeneration += 1
            generation = sessionGeneration
            let saved = await persistence.saveToken(response.token)
            guard generation == sessionGeneration else { return }
            guard saved else {
                errorMessage = "Signed in, but the session could not be stored in the Keychain. Check Keychain Access and try again."
                return
            }
            loadedToken = response.token
            await persistence.saveSnapshot(CachedAccessSnapshot(snapshot: response.snapshot, fetchedAt: clock()))
            guard generation == sessionGeneration else { return }
            serverSnapshot = response.snapshot
            apply(AccessGatePolicy.decide(.init(hasToken: true, fresh: .success(response.snapshot), cached: nil, now: clock(), ownerLicense: ownerLicense.license)))
            welcomeRequestID = UUID()
        } catch {
            guard generation == sessionGeneration else { return }
            errorMessage = (error as? AccessAPIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Local state goes first so the UI flips immediately even when the
    /// server is unreachable; revoking the token remotely is best effort.
    /// An owner license keeps the Mac unlocked through a server sign out.
    func signOut() async {
        let token = loadedToken
        forgetSession()
        apply(AccessGatePolicy.decide(.init(hasToken: false, fresh: nil, cached: nil, now: clock(), ownerLicense: ownerLicense.license)))
        await persistence.clear()
        if let token {
            try? await client.logout(token: token)
        }
    }

    // MARK: - Owner license

    /// Verifies the chosen file against this Mac before storing it, then
    /// re-evaluates so the gate drops immediately.
    func installOwnerLicense(from fileURL: URL) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try ownerLicenseGate.install(from: fileURL, now: clock())
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await evaluate()
    }

    func removeOwnerLicense() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try ownerLicenseGate.remove()
        } catch {
            errorMessage = error.localizedDescription
        }
        await evaluate()
    }

    private func forgetSession() {
        sessionGeneration += 1
        welcomeRequestID = nil
        loadedToken = nil
        serverSnapshot = nil
        plans = nil
        plansError = nil
        stopCheckoutPolling()
    }

    // MARK: - Billing

    func loadPlans() async {
        guard !isLoadingPlans else { return }
        let generation = sessionGeneration
        isLoadingPlans = true
        plansError = nil
        defer { isLoadingPlans = false }
        do {
            let response = try await client.plans()
            guard generation == sessionGeneration else { return }
            plans = response
        } catch {
            guard generation == sessionGeneration else { return }
            plansError = (error as? AccessAPIError)?.errorDescription ?? error.localizedDescription
        }
    }

    func startCheckout(plan: String) async {
        guard !isBusy, let token = loadedToken else { return }
        let generation = sessionGeneration
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let url = try await client.checkoutURL(token: token, plan: plan)
            guard generation == sessionGeneration else { return }
            openURL(url)
            startCheckoutPolling()
        } catch {
            guard generation == sessionGeneration else { return }
            errorMessage = (error as? AccessAPIError)?.errorDescription ?? error.localizedDescription
        }
    }

    func openBillingPortal() async {
        guard !isBusy, let token = loadedToken else { return }
        let generation = sessionGeneration
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let url = try await client.portalURL(token: token)
            guard generation == sessionGeneration else { return }
            openURL(url)
        } catch {
            guard generation == sessionGeneration else { return }
            errorMessage = (error as? AccessAPIError)?.errorDescription ?? error.localizedDescription
        }
    }

    @discardableResult
    func handleDeepLink(_ url: URL) -> Bool {
        guard let link = AccessDeepLink.parse(url) else { return false }
        switch link {
        case .billingSuccess, .billingPortal:
            startCheckoutPolling(interval: 2)
        case .billingCancel:
            stopCheckoutPolling()
        }
        return true
    }

    /// After Checkout opens in the browser, poll until the webhook lands.
    private func startCheckoutPolling(interval: TimeInterval = 4) {
        isAwaitingCheckout = true
        scheduler.startCheckoutPolling(
            interval: interval,
            verify: { [weak self] in
                guard let self else { return true }
                await self.evaluate()
                return self.isAllowed
            },
            onFinished: { [weak self] in self?.isAwaitingCheckout = false }
        )
    }

    private func stopCheckoutPolling() {
        scheduler.stopCheckoutPolling()
        isAwaitingCheckout = false
    }

    /// Re-verifies on a long interval so revoked subscriptions lapse
    /// without a relaunch. Call once after launch completes.
    func startPeriodicVerification(every interval: TimeInterval = 6 * 60 * 60) {
        scheduler.startPeriodic(every: interval) { [weak self] in
            guard let self else { return false }
            await self.evaluate()
            return true
        }
    }

    // MARK: - State transitions

    private func apply(_ newState: AccessGateState) {
        let wasAllowed = state.isAllowed
        state = newState
        if newState.isAllowed { stopCheckoutPolling() }
        if !wasAllowed, newState.isAllowed { onAccessGranted?() }
        if wasAllowed, !newState.isAllowed { onAccessRevoked?() }
    }
}
