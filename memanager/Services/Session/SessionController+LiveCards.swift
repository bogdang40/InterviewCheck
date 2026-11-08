import Foundation

extension SessionController {
    var activeLiveResponseCard: ResponseCard? {
        guard liveResponseCards.indices.contains(activeLiveResponseCardIndex) else {
            return liveResponseCards.first
        }
        return liveResponseCards[activeLiveResponseCardIndex]
    }
    func dismissHubNudge() {
        activeHubNudge = nil
        activeInterviewMoment = nil
        liveResponseCards = []
        interviewSignalEngine.dismissCurrentNudge()
    }
    func cycleLiveResponseCard() {
        guard !liveResponseCards.isEmpty else { return }
        activeLiveResponseCardIndex = (activeLiveResponseCardIndex + 1) % liveResponseCards.count
        guard let card = activeLiveResponseCard,
              let moment = activeInterviewMoment else { return }
        self.logger.logResponseCardEvent(
            name: "response_card_shown",
            sessionId: session.id.uuidString,
            momentId: moment.id,
            card: card,
            details: "cycled=true"
        )
    }
    func pinActiveResponseCardToTeleprompter() {
        guard let card = activeLiveResponseCard,
              let moment = activeInterviewMoment else { return }
        teleprompterPinnedResponseCard = card
        teleprompterModeEnabled = true
        self.logger.logResponseCardEvent(
            name: "response_card_pinned",
            sessionId: session.id.uuidString,
            momentId: moment.id,
            card: card
        )
    }
    func dismissLiveResponseCard() {
        guard let card = activeLiveResponseCard,
              let moment = activeInterviewMoment else {
            dismissHubNudge()
            return
        }
        self.logger.logResponseCardEvent(
            name: "response_card_dismissed",
            sessionId: session.id.uuidString,
            momentId: moment.id,
            card: card
        )
        dismissHubNudge()
    }
    @MainActor
    func refineActiveResponseCard() {
        guard let card = activeLiveResponseCard,
              let moment = activeInterviewMoment else { return }
        showQuickAssist(clearInputs: false)
        quickAssistQuestion = card.teleprompterText
        quickAssistExtraContextExpanded = true
        quickAssistExtraContext = "Refine this live response into a tighter interview answer.\n\nMoment: \(moment.summary)\nCue: \(moment.cueText)"
        quickAssistContextStatusMessage = "Refining a live response card in the active Quick Assist thread."
        switch card.type {
        case .clarify:
            setQuickAssistRouteOverride(.clarify)
        case .tradeoff:
            setQuickAssistRouteOverride(.walkthrough)
        case .complexity:
            setQuickAssistRouteOverride(.debug)
        case .pushback:
            setQuickAssistRouteOverride(.conversation)
        case .takeLead:
            setQuickAssistRouteOverride(.conversation)
        }
        self.logger.logResponseCardEvent(
            name: "response_card_refined",
            sessionId: session.id.uuidString,
            momentId: moment.id,
            card: card
        )
    }
}
