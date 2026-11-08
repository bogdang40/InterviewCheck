import Foundation

// MARK: - Session Control Facades
//
// Role scoped views onto SessionController so the hotkey wiring layer (and
// future callers) can depend on a narrow capability instead of the whole
// controller. Every requirement mirrors the exact SessionController method
// signature, including per method @MainActor isolation, so the conformances
// at the bottom of this file compile with empty bodies.

/// Starting, pausing, ending, and resetting the interview session.
protocol SessionLifecycleControlling: AnyObject {
    func startSession()
    func togglePauseSession()
    func endSession()
    func resetSession()
}

/// Kicking off and cancelling AI solve requests.
protocol SolveControlling: AnyObject {
    func solve() async
    func solveSystemDesign() async
    func cancelActiveRequest()
}

/// Moving between mentor response sections.
protocol SectionNavigating: AnyObject {
    func nextSection()
    func previousSection()
    func jumpToSection(_ index: Int)
}

/// Stepping through implementation and system design progressive steps.
protocol StepNavigating: AnyObject {
    func nextImplementationStep()
    func previousImplementationStep()
    func nextSystemDesignProgressiveStepByHotkey()
    func previousSystemDesignProgressiveStepByHotkey()
}

/// Triggering Quick Assist generations.
protocol QuickAssistTriggering: AnyObject {
    @MainActor func triggerQuickAssist()
    @MainActor func triggerQuickAssist(mode: QuickAssistContextMode, forceTier: QuickAssistModelTier?)
    @MainActor func triggerQuickAssistFollowUp()
    @MainActor func triggerQuickAssistAutoSideQuestionFromSelectedResponse()
}

extension QuickAssistTriggering {
    /// Mirrors SessionController's default `mode` argument, which a protocol
    /// requirement cannot express. Forwards to the full requirement.
    @MainActor
    func triggerQuickAssist(forceTier: QuickAssistModelTier?) {
        triggerQuickAssist(mode: .conversation, forceTier: forceTier)
    }

    /// Mirrors SessionController's default `forceTier` argument, which a
    /// protocol requirement cannot express. Forwards to the full requirement.
    @MainActor
    func triggerQuickAssist(mode: QuickAssistContextMode) {
        triggerQuickAssist(mode: mode, forceTier: nil)
    }
}

/// Presenting and focusing the Quick Assist workspace.
protocol QuickAssistViewControlling: AnyObject {
    @MainActor func showQuickAssist(clearInputs: Bool)
    @MainActor func focusQuickAssistQuestionInput()
    @MainActor func focusQuickAssistHistorySearch()
    func cycleQuickAssistThreadMode()
}

/// Navigating Quick Assist turns and history threads.
protocol QuickAssistHistoryNavigating: AnyObject {
    func selectNextQuickAssistTurn()
    func selectPreviousQuickAssistTurn()
    func selectNextQuickAssistHistoryThread()
    func selectPreviousQuickAssistHistoryThread()
    func openSelectedQuickAssistHistoryThread()
}

/// Teleprompter mode and chunk navigation.
protocol TeleprompterControlling: AnyObject {
    func toggleTeleprompterMode()
    func nextChunk()
    func previousChunk()
}

/// Cycling and pinning live response cards.
protocol LiveResponseCardControlling: AnyObject {
    func cycleLiveResponseCard()
    func pinActiveResponseCardToTeleprompter()
}

/// Cycling between configured AI providers.
protocol ProviderCycling: AnyObject {
    func cycleProvider()
}

/// Showing the transcript log view.
protocol TranscriptLogPresenting: AnyObject {
    func showTranscriptLog()
}

/// Deciding whether shared hotkeys should be consumed in the current UI state.
protocol HotkeyConsumptionGating: AnyObject {
    func shouldConsumeTeleprompterHotkeys() -> Bool
    func shouldConsumeQuickAssistHistoryHotkeys() -> Bool
    /// Whether the system design surface is frontmost: design step
    /// navigation wins the shared Cmd+Option arrow chords while it is.
    func isSystemDesignSurfaceActive() -> Bool
    func shouldConsumeQuickAssistModeHotkeys() -> Bool
}

/// Handling keyboard driven overlay commands.
protocol OverlayCommandHandling: AnyObject {
    @MainActor @discardableResult func handleOverlayCommand(_ command: OverlayCommand) -> Bool
}

/// Every session facade the hotkey layer needs. SessionController satisfies
/// all of them, but tests can supply distinct fakes per role.
typealias SessionHotkeyFacades = SessionLifecycleControlling
    & SolveControlling
    & SectionNavigating
    & StepNavigating
    & QuickAssistTriggering
    & QuickAssistViewControlling
    & QuickAssistHistoryNavigating
    & TeleprompterControlling
    & LiveResponseCardControlling
    & ProviderCycling
    & TranscriptLogPresenting
    & HotkeyConsumptionGating
    & OverlayCommandHandling

// MARK: - SessionController Conformances

extension SessionController: SessionLifecycleControlling {}
extension SessionController: SolveControlling {}
extension SessionController: SectionNavigating {}
extension SessionController: StepNavigating {}
extension SessionController: QuickAssistTriggering {}
extension SessionController: QuickAssistViewControlling {}
extension SessionController: QuickAssistHistoryNavigating {}
extension SessionController: TeleprompterControlling {}
extension SessionController: LiveResponseCardControlling {}
extension SessionController: ProviderCycling {}
extension SessionController: TranscriptLogPresenting {}
extension SessionController: HotkeyConsumptionGating {}
extension SessionController: OverlayCommandHandling {}
