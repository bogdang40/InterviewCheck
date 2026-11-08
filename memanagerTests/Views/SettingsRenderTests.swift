import AppKit
import SwiftUI
import XCTest
@testable import memanager

/// Renders every settings pane at three widths, the access gate in each of
/// its states, the account page, the enrollment wizard steps, and the live
/// test sheet. Opt in like `OverlayRenderSmokeTests`.
@MainActor
final class SettingsRenderTests: XCTestCase {
    private final class FakeClient: AccessAPIClienting {
        var meResult: Result<AccessSnapshot, AccessAPIError> = .failure(.network("offline"))
        func signup(email: String, password: String, adminSecret: String?) async throws -> SignedInResponse { throw AccessAPIError.network("n/a") }
        func login(email: String, password: String) async throws -> SignedInResponse { throw AccessAPIError.network("n/a") }
        func logout(token: String) async throws {}
        func me(token: String) async throws -> AccessSnapshot { try meResult.get() }
        func plans() async throws -> BillingPlans { BillingPlans(configured: true, plans: ["monthly", "annual"]) }
        func checkoutURL(token: String, plan: String) async throws -> URL { URL(string: "https://example.test")! }
        func portalURL(token: String) async throws -> URL { URL(string: "https://example.test")! }
    }

    private static let paneWidths: [CGFloat] = [400, 560, 900]

    override func setUpWithError() throws {
        try super.setUpWithError()
        try OverlayRenderHarness.skipUnlessEnabled()
    }

    private func snapshot(active: Bool) -> AccessSnapshot {
        let now = Date()
        return AccessSnapshot(
            user: AccountUser(id: "u1", email: "abe@example.com", role: .admin, disabled: false, createdAt: "2026-01-01T00:00:00Z", trialEndsAt: nil, complimentaryUntil: nil),
            entitlement: Entitlement(active: active, source: active ? .subscription : .none, expiresAt: nil, graceUntil: ISO8601DateParser.string(from: now.addingTimeInterval(86_400)), plan: "monthly", subscriptionStatus: active ? "active" : "canceled"),
            subscription: nil,
            serverTime: ISO8601DateParser.string(from: now)
        )
    }

    private func controller(token: String?, me: Result<AccessSnapshot, AccessAPIError>) async -> AccessController {
        let client = FakeClient()
        client.meResult = me
        let licenseGate = OwnerLicenseGate(store: MemoryOwnerLicenseStore(), verifier: OwnerLicenseVerifier(publicKeyBase64: OwnerLicenseVerifierTests.publicKey), deviceIdentity: FixedDeviceIdentity(id: nil))
        let controller = AccessController(client: client, tokenStore: MemoryAccessTokenStore(token: token), cache: MemoryAccessSnapshotCache(cached: nil), ownerLicenseGate: licenseGate, openURL: { _ in })
        await controller.evaluate()
        return controller
    }

    private func render<Content: View>(_ name: String, size: CGSize = CGSize(width: 800, height: 900), @ViewBuilder content: () -> Content) async throws {
        try await OverlayRenderHarness.render(name, size: size, content: content)
    }

    // MARK: Settings panes

    func testRenderEveryPaneAtBothWidths() async throws {
        for pane in SettingsPane.allCases {
            for width in Self.paneWidths {
                try await render("settings-\(pane.rawValue)-\(Int(width))", size: CGSize(width: width, height: 1000)) {
                    SettingsScreen(initialPane: pane)
                }
            }
        }
    }

    // MARK: Gate

    func testRenderSignInGate() async throws {
        let controller = await controller(token: nil, me: .failure(.network("offline")))
        try await render("gate-signin") { AccessGateView(controller: controller) }
        try await render("gate-signin-compact", size: CGSize(width: 420, height: 900)) { AccessGateView(controller: controller) }
        try await render("gate-create-account", size: CGSize(width: 600, height: 900)) {
            SignInView(controller: controller, isCreatingAccount: true)
                .overlayCard(.base, padding: DesignTokens.Spacing.lg)
                .padding(DesignTokens.Spacing.xxl)
        }
    }

    func testRenderPaywallGate() async throws {
        let controller = await controller(token: "t", me: .success(snapshot(active: false)))
        await controller.loadPlans()
        try await render("gate-paywall") { AccessGateView(controller: controller) }
        try await render("gate-paywall-compact", size: CGSize(width: 420, height: 900)) { AccessGateView(controller: controller) }
        await controller.startCheckout(plan: "monthly")
        try await render("gate-payment-pending", size: CGSize(width: 420, height: 900)) { AccessGateView(controller: controller) }
        await controller.signOut()
    }

    func testRenderModeEditorAndAdminActions() async throws {
        let suite = "ModeEditorRender.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ModeStore(defaults: defaults)
        var mode = store.addMode(title: "Payment systems", prompt: "Explain payment retries with a clear decision, failure cases and a practical tradeoff.")
        mode.projectFolder = ProjectFolderConfig(isEnabled: true)
        store.updateMode(mode)
        for width in [CGFloat(400), 700] {
            try await render("settings-mode-editor-\(Int(width))", size: CGSize(width: width, height: 1000)) {
                ScrollView {
                    ModeEditorColumn(store: store, mode: mode)
                        .padding(OverlayLayout.stageInset)
                }
                .environment(\.settingsBreakpoint, OverlayLayout.breakpoint(for: width))
            }
        }

        let snapshot = snapshot(active: true)
        let account = AdminUserView(user: snapshot.user, entitlement: snapshot.entitlement, subscription: nil, lastLoginAt: nil)
        try await render("settings-admin-actions", size: CGSize(width: 400, height: 420)) {
            SettingsSection("Accounts") {
                AdminUserRow(view: account, isSelf: true, onAction: { _ in })
                AdminUserRow(view: account, isSelf: false, isUpdating: true, onAction: { _ in })
            }
            .environment(\.settingsBreakpoint, .compact)
            .padding(OverlayLayout.stageInset)
        }
    }

    func testRenderUnreachableGate() async throws {
        let controller = await controller(token: "t", me: .failure(.network("The connection timed out.")))
        try await render("gate-unreachable") { AccessGateView(controller: controller) }
    }

    // MARK: Account

    func testRenderAccountPage() async throws {
        let controller = await controller(token: "fixture", me: .success(snapshot(active: true)))
        try await render("screen-account") { AccountSettingsView(controller: controller).padding(OverlayLayout.stageInset) }
    }

    func testRenderSetupAndOwnerLicenseRoutes() async throws {
        let controller = await controller(token: nil, me: .failure(.network("offline")))
        try await render("access-checking", size: CGSize(width: 400, height: 500)) { AccessCheckingView() }
        try await render("settings-readiness", size: CGSize(width: 560, height: 900)) { SessionReadinessView(onBack: {}) }
        try await render("settings-owner-license", size: CGSize(width: 480, height: 700)) {
            OwnerLicensePage(controller: controller, onBack: {}).padding(OverlayLayout.stageInset)
        }
    }

    // MARK: Voice sheets

    func testRenderEnrollmentWizardSteps() async throws {
        let service = VoiceSignatureEnrollmentService()
        let steps: [(String, EnrollmentStep, Bool)] = [
            ("instructions", .instructions, true),
            ("instructions-no-mic", .instructions, false),
            ("preparing", .preparing, true),
            ("recording", .recording, true),
            ("saving", .exporting, true),
            ("completed", .completed, true),
            ("error", .error, true)
        ]
        for (name, step, micGranted) in steps {
            try await render("voice-enrollment-\(name)", size: EnrollmentWizardView.sheetSize) {
                EnrollmentWizardView(
                    enrollmentService: service,
                    preview: EnrollmentWizardPreview(step: step, micPermissionGranted: micGranted)
                )
            }
        }
    }

    func testRenderLiveTest() async throws {
        let scores: [Float] = (0..<50).map { index in
            let phase = Float(index) / 49
            return 0.45 + 0.45 * sin(phase * .pi) + (index % 7 == 0 ? 0.05 : 0)
        }
        let session = LiveTestSession.seeded(label: .me, score: 0.88, scores: scores, audioLevel: 0.42)
        try await render("voice-live-test", size: LiveTestView.sheetSize) {
            LiveTestView(session: session)
        }
        try await render("voice-live-test-idle", size: LiveTestView.sheetSize) {
            LiveTestView(session: LiveTestSession.seeded(label: .unknown, score: 0, scores: [], audioLevel: 0, isRunning: false))
        }
    }
}
