import Foundation

extension SessionController {
    func refreshCoachFindings() {
        guard settings.hubFailureCoachEnabled else {
            activeCoachFindings = []
            syncQuickAssistSelectedTurnMetadata()
            return
        }
        activeCoachFindings = workstreamTimelineRepository.loadActiveCoachFindings(
            sessionId: session.id.uuidString,
            threadId: activeQuickAssistThreadID,
            limit: 12
        )
        syncQuickAssistSelectedTurnMetadata()
    }
    func dismissCoachFinding(_ findingID: String) {
        workstreamTimelineRepository.updateCoachFindingStatus(
            id: findingID,
            status: .dismissed,
            dismissedAt: Date()
        )
        self.logger.logDebugEvent(
            category: "coach",
            name: "finding_dismissed",
            details: "id=\(findingID)"
        )
        refreshCoachFindings()
        refreshWorkstreamTimeline()
    }
    @MainActor
    func applyCoachSuggestion(_ findingID: String) {
        guard let finding = activeCoachFindings.first(where: { $0.id == findingID }) else { return }
        showQuickAssist(clearInputs: false)
        quickAssistQuestion = finding.suggestedQuestion
        quickAssistExtraContext = finding.suggestedContext
        quickAssistExtraContextExpanded = true
        quickAssistContextStatusMessage = finding.message

        if settings.hubFailureCoachAutoOpenTimeline,
           let threadId = finding.threadId {
            inspectThreadInTimeline(threadID: threadId)
        }

        workstreamTimelineRepository.updateCoachFindingStatus(
            id: findingID,
            status: .applied,
            dismissedAt: nil
        )
        self.logger.logDebugEvent(
            category: "coach",
            name: "suggestion_applied",
            details: "id=\(findingID), issue=\(finding.issueType.rawValue)"
        )
        refreshCoachFindings()
        refreshWorkstreamTimeline()
    }
    func evaluateProactiveFailureCoach(now: Date = Date(), force: Bool = false) {
        guard settings.hubFailureCoachEnabled else { return }
        if !force, let lastCoachEvaluationAt,
           now.timeIntervalSince(lastCoachEvaluationAt) < 10 {
            return
        }

        let captureState = audioService.captureState
        let input = ProactiveFailureCoachInput(
            sessionId: session.id.uuidString,
            activeThreadId: activeQuickAssistThreadID,
            isCaptureActive: captureState == .recording || captureState == .starting,
            lastTranscriptAt: session.transcriptEntries.last?.timestamp,
            now: now
        )
        let findings = proactiveFailureCoachEngine.evaluate(input: input)
        let crossSessionFindings = crossSessionCoach.evaluate(
            report: cachedSkillReport,
            sessionId: session.id.uuidString
        )
        let allFindings = findings + crossSessionFindings
        for finding in allFindings {
            workstreamTimelineRepository.upsertCoachFinding(finding)
            self.logger.logDebugEvent(
                category: "coach",
                name: "finding_created",
                details: "issue=\(finding.issueType.rawValue), severity=\(finding.severity.rawValue)"
            )
        }
        lastCoachEvaluationAt = now
        refreshCoachFindings()
        if !allFindings.isEmpty {
            refreshWorkstreamTimeline()
        }
    }
    func applyQuickAssistTurnFeedback(_ feedback: QuickAssistTurnFeedback) {
        let normalizedTurnID = feedback.turnID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTurnID.isEmpty else { return }
        let acceptance = feedback.accepted ? "accepted" : "rejected"
        let normalizedNote = feedback.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedThreadID: String? = {
            if let selectedQuickAssistTurn,
               selectedQuickAssistTurn.id.uuidString == normalizedTurnID {
                return activeQuickAssistThreadID
            }
            if let matched = quickAssistCallByTurnID.first(where: { $0.key.uuidString == normalizedTurnID })?.value {
                return matched.threadId
            }
            return activeQuickAssistThreadID
        }()
        guard let resolvedThreadID else { return }
        self.logger.updateQuickAssistCallFeedback(
            threadId: resolvedThreadID,
            turnId: normalizedTurnID,
            status: feedback.status,
            note: normalizedNote?.isEmpty == true ? nil : normalizedNote
        )
        self.logger.logDebugEvent(
            category: "quick_assist_feedback",
            name: "turn_feedback",
            details: "turn_id=\(normalizedTurnID), result=\(acceptance), note=\(normalizedNote ?? "none")"
        )
        let refreshed = workstreamTimelineRepository.loadQuickAssistCalls(threadId: resolvedThreadID)
        cacheQuickAssistCallMetadata(refreshed)
        syncQuickAssistSelectedTurnMetadata()
        refreshWorkstreamTimeline()
    }
    @MainActor
    func applyQuickAssistRecoveryAction(_ action: QuickAssistRecoveryAction) {
        switch action.kind {
        case .askClarifyingFollowUp:
            showQuickAssist(clearInputs: false)
            quickAssistQuestion = action.suggestedQuestion ?? "What assumption should I verify before continuing?"
            quickAssistExtraContextExpanded = quickAssistExtraContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            quickAssistContextStatusMessage = action.note
            setQuickAssistRouteOverride(.clarify)
        case .retryDeep:
            retrySelectedQuickAssistTurnOnDeepTier(note: action.note)
        case .openTimeline:
            if let threadID = activeQuickAssistThreadID ?? quickAssistCoordinator.activeThreadId {
                inspectThreadInTimeline(threadID: threadID)
            }
        }
    }
    @MainActor
    private func retrySelectedQuickAssistTurnOnDeepTier(note: String?) {
        guard let selectedTurn = selectedQuickAssistTurn ?? quickAssistTurns.last else { return }
        showQuickAssist(clearInputs: false)
        quickAssistQuestion = selectedTurn.question
        quickAssistContextStatusMessage = note ?? "Retrying the selected turn on the deep tier."
        quickAssist(
            isFollowUp: false,
            mode: selectedTurn.contextMode,
            forceTier: .deep,
            questionOverride: selectedTurn.question,
            questionSourceOverride: selectedTurn.questionSource == .none ? .manual : selectedTurn.questionSource
        )
    }
}
