import SwiftUI
import XCTest
@testable import memanager

@MainActor
final class FloatingShellRenderFixture {
    static let borderWidth: CGFloat = 6
    static let question = "How would you prevent duplicate payments?"
    static let answer = """
    **Say first:** I would use an idempotency key so retries cannot create duplicate payments.

    ### Approach
    Store the key and the result with the payment. Return the same result on a retry.

    ### Tradeoff
    Keep keys long enough to cover delayed retries.

    ### Next step
    Define the key scope and test concurrent retries.
    """

    private var restoration: [() -> Void] = []

    static func install(hasAnswer: Bool = true, style: BorderShaderStyle = .liquid) async throws -> FloatingShellRenderFixture {
        try XCTSkipUnless(TestRuntime.isRunningUnitTests, "A hosted XCTest process is required for isolated stores.")
        try XCTSkipUnless(AppDefaults.standard !== UserDefaults.standard, "Live app preferences must not be used.")
        let controller = SessionController.shared
        let audio = AudioCaptureService.shared
        try XCTSkipUnless(!controller.isLoading && !controller.isQuickAssistLoading && !audio.isEngineRunning,
                         "The synthetic render must not interrupt an active request or capture.")
        // Let singleton initialization deliver its initial Combine state before
        // setting the fixture. No capture or provider method is invoked here.
        try await Task.sleep(for: .milliseconds(100))
        let fixture = FloatingShellRenderFixture()
        let settings = SettingsManager.shared
        let previousLiquid = settings.liquidBorderConfiguration
        fixture.restoration.append { settings.updateConfiguration(previousLiquid, for: .liquid) }
        var liquid = BorderShaderConfiguration.liquidDefault
        liquid.width = Double(borderWidth)
        liquid.animationEnabled = false
        settings.updateConfiguration(liquid, for: .liquid)
        fixture.put(settings, \.borderShaderStyle, style)
        fixture.put(settings, \.overlayAppearance, .dark)
        fixture.put(settings, \.overlayOpacity, 0.75)
        fixture.put(settings, \.fontSize, 16)
        fixture.put(settings, \.practiceStudioEnabled, false)
        fixture.put(settings, \.canvasModeEnabled, false)
        fixture.put(settings, \.hubProactiveNudgesEnabled, false)

        var session = Session()
        session.state = .listening
        fixture.put(controller, \.session, session)
        fixture.put(audio, \.isRecording, true)
        fixture.put(audio, \.errorMessage, nil)
        fixture.put(controller, \.isQuickAssistViewVisible, true)
        fixture.put(controller, \.isTranscriptViewVisible, false)
        fixture.put(controller, \.isMLGuideViewVisible, false)
        fixture.put(controller, \.isPracticeStudioVisible, false)
        fixture.put(controller, \.isStreaming, false)
        fixture.put(controller, \.errorMessage, nil)
        fixture.put(controller, \.quickAssistQuestion, "")
        fixture.put(controller, \.quickAssistQuestionFocusNonce, 0)
        fixture.put(controller, \.quickAssistHistorySearchFocusNonce, 0)
        fixture.put(controller, \.quickAssistStreamingDraft, nil)
        fixture.put(controller, \.quickAssistInterruptedAnswer, nil)
        fixture.put(controller, \.quickAssistContextStatusMessage, nil)
        fixture.put(controller, \.quickAssistRouteSummary, nil)
        fixture.put(controller, \.quickAssistVerificationRecord, nil)
        fixture.put(controller, \.quickAssistSelectedTurnFeedbackStatus, .none)
        fixture.put(controller, \.quickAssistRecoveryPlan, nil)
        fixture.put(controller, \.activeHubNudge, nil)
        fixture.put(controller, \.activeCoachFindings, [])
        fixture.put(controller, \.teleprompterModeEnabled, false)
        let turn = QuickAssistThread.Turn(
            id: UUID(uuidString: "993B5429-D89D-4D4D-817C-B4BC673FBA33")!,
            timestamp: Date(timeIntervalSince1970: 1_783_296_000), transcriptDelta: "",
            question: question, response: answer, provider: .claude,
            contextMode: .conversation, modelTier: .fast)
        fixture.put(controller, \.quickAssistTurns, hasAnswer ? [turn] : [])
        fixture.put(controller, \.selectedQuickAssistTurnIndex, hasAnswer ? 0 : nil)
        fixture.put(controller, \.quickAssistResponse, hasAnswer ? answer : nil)
        fixture.put(controller, \.quickAssistLastStableResponse, nil)
        fixture.put(controller, \.quickAssistLastStableTurnID, nil)
        let previousScreen = OverlayNavigator.shared.screen
        fixture.restoration.append { OverlayNavigator.shared.show(previousScreen) }
        OverlayNavigator.shared.show(.mentor)
        return fixture
    }

    func restore() {
        restoration.reversed().forEach { $0() }
        restoration.removeAll()
    }

    private func put<Object: AnyObject, Value>(_ object: Object,
        _ keyPath: ReferenceWritableKeyPath<Object, Value>, _ value: Value) {
        let previous = object[keyPath: keyPath]
        restoration.append { object[keyPath: keyPath] = previous }
        object[keyPath: keyPath] = value
    }
}

/// Uses production shell and native material together, without account or
/// welcome presentation and without the old opaque render harness wrapper.
struct FloatingShellRenderContent: View {
    let size: CGSize
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        let geometry = FloatingShellGeometry(size: size,
            borderWidth: CGFloat(settings.configuration(for: settings.borderShaderStyle)?.width ?? 0))
        ZStack(alignment: .topLeading) {
            FloatingGlassBackdrop(geometry: geometry).allowsHitTesting(false)
            OverlayShellView(width: size.width)
            Image("AbleyLogo")
                .resizable()
                .scaledToFit()
                .frame(width: AbleyWelcomeMotion.dockSize, height: AbleyWelcomeMotion.dockSize)
                .position(geometry.brandCenter)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(width: size.width, height: size.height)
        .tint(OverlayPalette.accent)
        .environment(\.colorScheme, .dark)
        .environment(\.overlayContentIsVisible, true)
    }
}
