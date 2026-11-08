import Foundation

protocol SessionDebriefComposing {
    func compose(
        sessionId: String,
        transcriptEntries: [TranscriptEntryRecord],
        quickAssistCalls: [QuickAssistCallRecord],
        coachFindings: [CoachFindingRecord],
        responseCardEvents: [WorkstreamTimelineEvent],
        existingDebriefId: String?
    ) async -> SessionDebrief?
}

struct TemplateSessionDebriefComposer: SessionDebriefComposing {
    func compose(
        sessionId: String,
        transcriptEntries: [TranscriptEntryRecord],
        quickAssistCalls: [QuickAssistCallRecord],
        coachFindings: [CoachFindingRecord],
        responseCardEvents: [WorkstreamTimelineEvent],
        existingDebriefId: String? = nil
    ) async -> SessionDebrief? {
        let transcriptWordCount = transcriptEntries.reduce(0) { partial, entry in
            partial + entry.text.split(separator: " ").count
        }

        guard transcriptWordCount >= 150 || !quickAssistCalls.isEmpty else {
            return nil
        }

        let sortedCalls = quickAssistCalls.sorted { $0.startedAt < $1.startedAt }
        let successfulCalls = sortedCalls.filter { $0.status == "success" }
        let weakCalls = sortedCalls.filter { $0.verificationStatus == .failed || $0.verificationStatus == .needsReview }
        let strongestCall = successfulCalls.max {
            (score(for: $0), $0.startedAt) < (score(for: $1), $1.startedAt)
        }
        let weakestCall = weakCalls.min {
            (score(for: $0), $0.startedAt) < (score(for: $1), $1.startedAt)
        } ?? sortedCalls.min {
            (score(for: $0), $0.startedAt) < (score(for: $1), $1.startedAt)
        }

        let responseCardCount = responseCardEvents.count
        let whatHappened = [
            "Recorded \(transcriptWordCount) transcript words across \(transcriptEntries.count) transcript entries.",
            "Ran \(sortedCalls.count) Quick Assist turns with \(successfulCalls.count) successful completions.",
            responseCardCount > 0 ? "Live response cards fired \(responseCardCount) times during the session." : "No live response cards were captured."
        ]

        let strongMoments = [
            strongestCall.map {
                "Best grounded turn: \($0.question ?? "Quick Assist") with \($0.verificationStatus.displayLabel.lowercased()) verification and \($0.durationMs ?? 0)ms latency."
            } ?? "No verified Quick Assist turn was available.",
            coachFindings.isEmpty ? "No proactive coach escalations were raised." : "Coach raised \(coachFindings.count) findings, which highlights where the system saw friction."
        ]

        let missedOpportunities = [
            weakestCall.map {
                "Weakest moment: \($0.question ?? "Quick Assist") with \($0.verificationStatus.displayLabel.lowercased()) verification and \(max(0, $0.unsupportedClaimCount ?? 0)) unsupported claims."
            } ?? "There was not enough evidence to isolate a single weak turn.",
            responseCardCount == 0 ? "The session did not capture enough live prompts, so proactive steering was limited." : "Review the live prompts that were dismissed or refined for missed conversational openings."
        ]

        let recommendedDrills = [
            "Clarification drill to force the first assumption into the open before you answer.",
            "Tradeoff drill to tie each design decision to one explicit cost.",
            "Recovery drill to respond cleanly when the interviewer pushes back."
        ]

        let nextSessionFocus = [
            weakestCall?.verificationStatus == .failed
                ? "Start the next session by slowing down and validating assumptions before depth."
                : "Keep the same response pace, but tighten the first sentence of each answer.",
            "Use Quick Assist follow-up only after the main claim is stated clearly."
        ]

        let debriefId = existingDebriefId ?? UUID().uuidString
        let createdAt = Date()
        let drills = buildDrills(
            sessionId: sessionId,
            debriefId: debriefId,
            weakestCall: weakestCall,
            strongestCall: strongestCall
        )

        return SessionDebrief(
            id: debriefId,
            sessionId: sessionId,
            whatHappened: whatHappened,
            strongMoments: strongMoments,
            missedOpportunities: missedOpportunities,
            recommendedDrills: recommendedDrills,
            nextSessionFocus: nextSessionFocus,
            createdAt: createdAt,
            updatedAt: createdAt,
            drills: drills
        )
    }

    private func score(for call: QuickAssistCallRecord) -> Double {
        let statusScore: Double
        switch call.verificationStatus {
        case .verified:
            statusScore = 4
        case .needsReview:
            statusScore = 2
        case .pending:
            statusScore = 1
        case .failed:
            statusScore = 0
        }

        return statusScore - Double(max(0, call.unsupportedClaimCount ?? 0)) * 0.5
    }

    private func buildDrills(
        sessionId: String,
        debriefId: String,
        weakestCall: QuickAssistCallRecord?,
        strongestCall: QuickAssistCallRecord?
    ) -> [SessionDrill] {
        let now = Date()
        let clarificationPrompt = weakestCall?.question ?? "What is the key assumption you would clarify before you continue?"
        let tradeoffPrompt = strongestCall?.question ?? "Explain the main tradeoff in your approach and why it fits the constraints."
        let recoveryPrompt = weakestCall?.verificationSuggestedFollowUp ?? "The interviewer says your first answer is not enough. Recover the answer cleanly."

        return [
            SessionDrill(
                id: UUID().uuidString,
                sessionId: sessionId,
                debriefId: debriefId,
                kind: .clarification,
                title: "Clarify Before Committing",
                prompt: clarificationPrompt,
                transcriptSpan: weakestCall?.transcriptText ?? "",
                relatedThreadId: weakestCall?.threadId,
                relatedTurnId: weakestCall?.turnId,
                createdAt: now
            ),
            SessionDrill(
                id: UUID().uuidString,
                sessionId: sessionId,
                debriefId: debriefId,
                kind: .tradeoff,
                title: "Name The Tradeoff",
                prompt: tradeoffPrompt,
                transcriptSpan: strongestCall?.transcriptText ?? "",
                relatedThreadId: strongestCall?.threadId,
                relatedTurnId: strongestCall?.turnId,
                createdAt: now
            ),
            SessionDrill(
                id: UUID().uuidString,
                sessionId: sessionId,
                debriefId: debriefId,
                kind: .recovery,
                title: "Recover Under Pushback",
                prompt: recoveryPrompt,
                transcriptSpan: weakestCall?.transcriptText ?? "",
                relatedThreadId: weakestCall?.threadId,
                relatedTurnId: weakestCall?.turnId,
                createdAt: now
            )
        ]
    }
}
