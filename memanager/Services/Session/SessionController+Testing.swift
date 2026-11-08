import Foundation

#if DEBUG
extension SessionController {
    @MainActor
    func resetSessionStateForTesting() {
        prepareForNewSession()
    }
    @MainActor
    func resumeSessionForTesting(sessionID: UUID) async {
        await resumeSessionAsync(sessionID: sessionID)
    }
    @MainActor
    func startSessionForTesting() async {
        await startSessionAsync()
    }
    @MainActor
    func syncSessionStateForTesting(with state: AudioCaptureService.CaptureState) {
        syncSessionState(with: state)
    }
    @MainActor
    func quickAssistSectionContextForTesting(mode: QuickAssistContextMode) -> String {
        buildQuickAssistSectionContext(for: mode)
    }
    @MainActor
    func quickAssistSectionWarningForTesting(mode: QuickAssistContextMode) -> String? {
        let sectionContext = buildQuickAssistSectionContext(for: mode)
        return sectionContextWarning(for: mode, sectionContext: sectionContext)
    }
    @MainActor
    func quickAssistOutputContractStatusForTesting(
        mode: QuickAssistContextMode,
        contract: QuickAssistOutputContract
    ) -> String {
        quickAssistOutputContractStatus(mode: mode, contract: contract)
    }
    @MainActor
    func setActiveQuickAssistRequestIDForTesting(_ requestID: UUID) {
        activeQuickAssistRequestID = requestID
    }
    @MainActor
    func applyQuickAssistStreamUpdateForTesting(
        _ response: String,
        sessionID: UUID,
        requestID: UUID
    ) -> Bool {
        applyQuickAssistStreamUpdate(response, sessionID: sessionID, requestID: requestID)
    }
    @MainActor
    func behaviouralResponseStyleForTesting(
        question: String,
        transcript: String,
        source: QuickAssistQuestionSource
    ) -> BehaviouralResponseStyleDecision {
        behaviouralResponseStyleResolver.resolve(
            question: question,
            transcript: transcript,
            questionSource: source
        )
    }
}
#endif
