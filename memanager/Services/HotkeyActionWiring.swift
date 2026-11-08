import AppKit

/// Binds HotkeyManager callbacks to role scoped session facades.
///
/// Extracted from AppDelegate.setupHotkeyActions() so the app delegate only
/// keeps the closures that drive its own windows and overlay state. Every
/// closure body here is identical to the original wiring, with
/// SessionController.shared replaced by the injected facade that covers the
/// call. Assignment order matches the original order of the moved set.
@MainActor
final class HotkeyActionWiring {
    /// Explicit editor shortcuts may request keyboard focus; passive viewing does not.
    var prepareForTextInput: () -> Bool = { true }
    private let hotkeyManager: HotkeyManager
    private let sessionLifecycle: any SessionLifecycleControlling
    private let solveControl: any SolveControlling
    private let sectionNavigation: any SectionNavigating
    private let stepNavigation: any StepNavigating
    private let quickAssist: any QuickAssistTriggering
    private let quickAssistView: any QuickAssistViewControlling
    private let quickAssistHistory: any QuickAssistHistoryNavigating
    private let teleprompter: any TeleprompterControlling
    private let liveResponseCards: any LiveResponseCardControlling
    private let providerCycling: any ProviderCycling
    private let transcriptLog: any TranscriptLogPresenting
    private let hotkeyGating: any HotkeyConsumptionGating
    private let overlayCommands: any OverlayCommandHandling

    init(
        hotkeyManager: HotkeyManager,
        sessionLifecycle: any SessionLifecycleControlling,
        solveControl: any SolveControlling,
        sectionNavigation: any SectionNavigating,
        stepNavigation: any StepNavigating,
        quickAssist: any QuickAssistTriggering,
        quickAssistView: any QuickAssistViewControlling,
        quickAssistHistory: any QuickAssistHistoryNavigating,
        teleprompter: any TeleprompterControlling,
        liveResponseCards: any LiveResponseCardControlling,
        providerCycling: any ProviderCycling,
        transcriptLog: any TranscriptLogPresenting,
        hotkeyGating: any HotkeyConsumptionGating,
        overlayCommands: any OverlayCommandHandling
    ) {
        self.hotkeyManager = hotkeyManager
        self.sessionLifecycle = sessionLifecycle
        self.solveControl = solveControl
        self.sectionNavigation = sectionNavigation
        self.stepNavigation = stepNavigation
        self.quickAssist = quickAssist
        self.quickAssistView = quickAssistView
        self.quickAssistHistory = quickAssistHistory
        self.teleprompter = teleprompter
        self.liveResponseCards = liveResponseCards
        self.providerCycling = providerCycling
        self.transcriptLog = transcriptLog
        self.hotkeyGating = hotkeyGating
        self.overlayCommands = overlayCommands
    }

    /// Convenience for production wiring where one object provides every facade.
    convenience init(hotkeyManager: HotkeyManager, sessionFacades: any SessionHotkeyFacades) {
        self.init(
            hotkeyManager: hotkeyManager,
            sessionLifecycle: sessionFacades,
            solveControl: sessionFacades,
            sectionNavigation: sessionFacades,
            stepNavigation: sessionFacades,
            quickAssist: sessionFacades,
            quickAssistView: sessionFacades,
            quickAssistHistory: sessionFacades,
            teleprompter: sessionFacades,
            liveResponseCards: sessionFacades,
            providerCycling: sessionFacades,
            transcriptLog: sessionFacades,
            hotkeyGating: sessionFacades,
            overlayCommands: sessionFacades
        )
    }

    /// Assigns every session bound hotkey callback.
    func wire() {
        wireSessionControlAndNavigation()
        wireQuickAssistTriggers()
        wireCaptureGatingAndTeleprompter()
        wireResponsesProviderAndOverlay()
    }

    // MARK: - Session Control and Navigation

    private func wireSessionControlAndNavigation() {
        let sessionLifecycle = self.sessionLifecycle
        let solveControl = self.solveControl
        let transcriptLog = self.transcriptLog
        let sectionNavigation = self.sectionNavigation
        let stepNavigation = self.stepNavigation

        // Start opens the interview setup; recording starts from there, after
        // the interviewer confirms the candidate was told.
        hotkeyManager.onStartSession = {
            Task { @MainActor in OverlayNavigator.shared.returnToMentor() }
        }

        hotkeyManager.onScreenshot = {
            ScreenshotService.shared.captureFullScreen()
        }

        // Cmd+Shift+Return: the interviewer just asked a question.
        hotkeyManager.onSolve = {
            Task { @MainActor in InterviewController.shared.markQuestion() }
        }

        hotkeyManager.onResetSession = {
            sessionLifecycle.resetSession()
        }

        hotkeyManager.onOpenTranscriptLog = {
            transcriptLog.showTranscriptLog()
        }

        hotkeyManager.onTogglePauseSession = {
            sessionLifecycle.togglePauseSession()
        }

        // Cmd+Shift+E: the candidate finished answering.
        hotkeyManager.onEndSession = {
            Task { @MainActor in InterviewController.shared.answerDone() }
        }

        hotkeyManager.onNextSection = {
            sectionNavigation.nextSection()
        }

        hotkeyManager.onPrevSection = {
            sectionNavigation.previousSection()
        }

        hotkeyManager.onJumpToSection = { index in
            sectionNavigation.jumpToSection(index)
        }

        hotkeyManager.onQuit = {
            NSApplication.shared.terminate(nil)
        }

        hotkeyManager.onNextStep = {
            stepNavigation.nextImplementationStep()
        }

        hotkeyManager.onPrevStep = {
            stepNavigation.previousImplementationStep()
        }

        hotkeyManager.onNextDesignStep = {
            stepNavigation.nextSystemDesignProgressiveStepByHotkey()
        }

        hotkeyManager.onPrevDesignStep = {
            stepNavigation.previousSystemDesignProgressiveStepByHotkey()
        }
    }

    // MARK: - Quick Assist Triggers

    private func wireQuickAssistTriggers() {
        let quickAssist = self.quickAssist

        hotkeyManager.onQuickAssist = {
            quickAssist.triggerQuickAssist()
        }

        hotkeyManager.onQuickAssistDeep = {
            quickAssist.triggerQuickAssist(forceTier: .deep)
        }

        hotkeyManager.onQuickAssistFollowUp = {
            quickAssist.triggerQuickAssistFollowUp()
        }

        // Section navigation (Cmd+1..6) and context-aware Quick Assist (Cmd+Option+1/2) are intentionally separate.
        hotkeyManager.onQuickAssistImplementationContext = {
            quickAssist.triggerQuickAssist(mode: .allSectionsContext)
        }

        hotkeyManager.onQuickAssistSystemDesignContext = {
            quickAssist.triggerQuickAssist(mode: .systemDesignContext)
        }
    }

    // MARK: - Capture, Gating, and Teleprompter

    private func wireCaptureGatingAndTeleprompter() {
        let hotkeyGating = self.hotkeyGating
        let teleprompter = self.teleprompter

        hotkeyManager.onMarkCurrentSpeakerAsMe = {
            AudioCaptureService.shared.markCurrentSpeakerAsMe()
        }

        hotkeyManager.onToggleSpeakerIdMode = {
            VoiceSignatureStore.shared.toggleSpeakerIdentificationMode()
        }

        hotkeyManager.onToggleDiagnostics = {
            SettingsManager.shared.showDiagnosticsOverlay.toggle()
        }

        hotkeyManager.shouldConsumeTeleprompterHotkeys = {
            hotkeyGating.shouldConsumeTeleprompterHotkeys()
        }

        hotkeyManager.shouldConsumeQuickAssistHistoryHotkeys = {
            hotkeyGating.shouldConsumeQuickAssistHistoryHotkeys()
        }
        hotkeyManager.isSystemDesignSurfaceActive = {
            hotkeyGating.isSystemDesignSurfaceActive()
        }

        hotkeyManager.shouldConsumeQuickAssistModeHotkeys = {
            hotkeyGating.shouldConsumeQuickAssistModeHotkeys()
        }

        hotkeyManager.onToggleTeleprompter = {
            teleprompter.toggleTeleprompterMode()
        }

        hotkeyManager.onNextChunk = {
            teleprompter.nextChunk()
        }

        hotkeyManager.onPrevChunk = {
            teleprompter.previousChunk()
        }
    }

    // MARK: - Responses, Provider, and Overlay

    private func wireResponsesProviderAndOverlay() {
        let prepareForTextInput = self.prepareForTextInput
        let solveControl = self.solveControl
        let quickAssist = self.quickAssist
        let quickAssistView = self.quickAssistView
        let quickAssistHistory = self.quickAssistHistory
        let liveResponseCards = self.liveResponseCards
        let providerCycling = self.providerCycling
        let overlayCommands = self.overlayCommands

        hotkeyManager.onSolveSystemDesign = {
            Task {
                await solveControl.solveSystemDesign()
            }
        }

        hotkeyManager.onNextQuickAssistResponse = {
            quickAssistHistory.selectNextQuickAssistTurn()
        }

        hotkeyManager.onPrevQuickAssistResponse = {
            quickAssistHistory.selectPreviousQuickAssistTurn()
        }

        hotkeyManager.onCancelRequest = {
            solveControl.cancelActiveRequest()
        }

        hotkeyManager.onCycleProvider = {
            providerCycling.cycleProvider()
        }

        hotkeyManager.onShowQuickAssistView = {
            quickAssistView.showQuickAssist(clearInputs: false)
        }

        hotkeyManager.onQuickAssistAutoSideQuestion = {
            quickAssist.triggerQuickAssistAutoSideQuestionFromSelectedResponse()
        }

        hotkeyManager.onFocusQuickAssistQuestion = {
            guard prepareForTextInput() else { return }
            quickAssistView.focusQuickAssistQuestionInput()
        }

        hotkeyManager.onCycleQuickAssistMode = {
            quickAssistView.cycleQuickAssistThreadMode()
        }

        hotkeyManager.onFocusQuickAssistHistorySearch = {
            guard prepareForTextInput() else { return }
            quickAssistView.focusQuickAssistHistorySearch()
        }

        hotkeyManager.onCycleLiveResponseCard = {
            liveResponseCards.cycleLiveResponseCard()
        }

        hotkeyManager.onPinLiveResponseCard = {
            liveResponseCards.pinActiveResponseCardToTeleprompter()
        }

        hotkeyManager.shouldRouteOverlayKeyboardInput = { false }

        hotkeyManager.onPerformOverlayCommand = { command in
            MainActor.assumeIsolated {
                overlayCommands.handleOverlayCommand(command)
            }
        }

        hotkeyManager.onNextQuickAssistHistoryThread = {
            quickAssistHistory.selectNextQuickAssistHistoryThread()
        }

        hotkeyManager.onPrevQuickAssistHistoryThread = {
            quickAssistHistory.selectPreviousQuickAssistHistoryThread()
        }

        hotkeyManager.onOpenQuickAssistHistoryThread = {
            quickAssistHistory.openSelectedQuickAssistHistoryThread()
        }
    }
}
