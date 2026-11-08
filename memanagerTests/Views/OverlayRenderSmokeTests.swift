import AppKit
import SwiftUI
import XCTest
@testable import memanager

/// Renders overlay screens and surfaces to PNG files for visual inspection.
/// Opt in through MEMANAGER_RENDER_SMOKE=1 (pass
/// TEST_RUNNER_MEMANAGER_RENDER_SMOKE=1 to xcodebuild); the files land in
/// MEMANAGER_RENDER_DIR or the temp dir. Fixtures live in
/// `OverlayRenderFixtures` so every surface renders with realistic data.
@MainActor
final class OverlayRenderSmokeTests: XCTestCase {
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

    private func render<Content: View>(_ name: String, size: CGSize = CGSize(width: 800, height: 900), @ViewBuilder content: () -> Content) async throws {
        try await OverlayRenderHarness.render(name, size: size, content: content)
    }

    // MARK: - Gate

    func testRenderSignInGate() async throws {
        let controller = AccessController(client: FakeClient(), tokenStore: MemoryAccessTokenStore(token: nil), cache: MemoryAccessSnapshotCache(cached: nil), openURL: { _ in })
        await controller.evaluate()
        try await render("gate-signin") { AccessGateView(controller: controller) }
    }

    func testRenderPaywallGate() async throws {
        let client = FakeClient()
        client.meResult = .success(snapshot(active: false))
        let controller = AccessController(client: client, tokenStore: MemoryAccessTokenStore(token: "t"), cache: MemoryAccessSnapshotCache(cached: nil), openURL: { _ in })
        await controller.evaluate()
        await controller.loadPlans()
        try await render("gate-paywall") { AccessGateView(controller: controller) }
    }

    // MARK: - Shell chrome

    func testRenderShellChrome() async throws {
        for (name, width) in [("shell-chrome-wide", CGFloat(1000)), ("shell-chrome-regular", CGFloat(720)), ("shell-chrome-compact", CGFloat(440))] {
            try await render(name, size: CGSize(width: width, height: 140)) {
                VStack(spacing: 0) {
                    OverlayRenderFixtures.commandBar(width: width, surface: .assist, screen: .mentor)
                    Hairline()
                    LiveStrip(
                        question: OverlayRenderFixtures.liveQuestion,
                        pacing: PacingBadgeModel(state: .decisive(confidence: 0.8), enabled: true),
                        onAnswer: {}
                    )
                    Spacer()
                    Hairline()
                    OverlayRenderFixtures.statusBar(width: width, surface: .assist)
                }
            }
        }
    }

    /// The whole shell over the live singletons (idle session), so the
    /// composition of bar, stage, drawer, and status bar can be inspected.
    func testRenderFullShell() async throws {
        for (name, width) in [("shell-full-wide", CGFloat(1000)), ("shell-full-regular", CGFloat(720)), ("shell-full-compact", CGFloat(400))] {
            try await render(name, size: CGSize(width: width, height: 700)) {
                OverlayShellView(width: width)
            }
        }
    }

    func testRenderLargeTextShell() async throws {
        let settings = SettingsManager.shared
        let originalFont = settings.fontSize
        defer { settings.fontSize = originalFont }
        settings.fontSize = 20
        for width: CGFloat in [400, 560, 900] {
            try await render("shell-large-text-\(Int(width))", size: CGSize(width: width, height: 760)) {
                OverlayShellView(width: width)
                    .pearlGlass(radius: OverlayLayout.panelCornerRadius)
            }
        }
    }

    // MARK: - Mentor surfaces

    func testRenderTranscriptSurface() async throws {
        try await render("surface-transcript") {
            TranscriptSurface(
                rows: OverlayRenderFixtures.transcriptRows,
                entryCount: OverlayRenderFixtures.transcriptRows.count,
                isRecording: true,
                error: nil,
                fontSize: 14,
                useSourceBasedIdentification: true,
                onSpeakerTapped: { _ in },
                onOpenSettings: {},
                onRetry: {},
                onDismissError: {},
                onClose: {}
            )
        }
    }

    func testRenderEmptyStates() async throws {
        try await render("surface-solve-empty") {
            SolveEmptyState(state: .idle, onStart: {}, onSolve: {}, onScreenshot: {}, onResume: {}, onEnd: {})
        }
        try await render("surface-solve-listening") {
            SolveEmptyState(state: .listening, onStart: {}, onSolve: {}, onScreenshot: {}, onResume: {}, onEnd: {})
        }
        try await render("surface-loading") {
            StageLoadingView(title: "Working through it", subtitle: "Restating the problem, planning the approach, then coding it step by step.", onCancel: {})
        }
    }

    func testRenderSolveSections() async throws {
        let response = OverlayRenderFixtures.codingResponse
        for section in MentorSurfaceResolver.solveSections {
            try await render("surface-solve-\(section.title.lowercased())") {
                SolveSectionContent(section: section, response: response, isStreaming: false, width: 800)
            }
        }
    }

    func testRenderDrawer() async throws {
        try await render("drawer-context", size: CGSize(width: 250, height: 700)) {
            ContextDrawer(onClose: {})
        }
    }

    // MARK: - Screens

    func testRenderShellScreens() async throws {
        try await render("screen-settings") { SettingsScreen() }
        try await render("screen-workspaces") { WorkspacesScreen() }
        try await render("screen-knowledge") { KnowledgeScreen() }
        try await render("screen-history") { SessionHistoryView() }
        try await render("screen-practice") { PracticeStudioView() }
        try await render("screen-account") { AccountSettingsView().scrollContentBackground(.hidden) }
        try await render("screen-settings-narrow", size: CGSize(width: 480, height: 900)) { SettingsScreen() }
    }
}
