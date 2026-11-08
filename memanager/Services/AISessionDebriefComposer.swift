import Foundation

/// AI-powered session debrief composer.
/// Orchestrates: evidence packager -> AI provider -> response parser.
/// Falls back to `TemplateSessionDebriefComposer` on any failure.
final class AISessionDebriefComposer: SessionDebriefComposing {

    private let evidencePackager: DebriefEvidencePackaging
    private let responseParser: DebriefResponseParsing
    private let templateFallback: TemplateSessionDebriefComposer
    private let aiProvider: AIProvider?

    init(
        aiProvider: AIProvider?,
        evidencePackager: DebriefEvidencePackaging = DebriefEvidencePackager(),
        responseParser: DebriefResponseParsing = DebriefResponseParser(),
        templateFallback: TemplateSessionDebriefComposer = TemplateSessionDebriefComposer()
    ) {
        self.aiProvider = aiProvider
        self.evidencePackager = evidencePackager
        self.responseParser = responseParser
        self.templateFallback = templateFallback
    }

    func compose(
        sessionId: String,
        transcriptEntries: [TranscriptEntryRecord],
        quickAssistCalls: [QuickAssistCallRecord],
        coachFindings: [CoachFindingRecord],
        responseCardEvents: [WorkstreamTimelineEvent],
        existingDebriefId: String?
    ) async -> SessionDebrief? {
        guard let context = evidencePackager.package(
            sessionId: sessionId,
            transcriptEntries: transcriptEntries,
            quickAssistCalls: quickAssistCalls,
            coachFindings: coachFindings,
            responseCardEvents: responseCardEvents,
            existingDebriefId: existingDebriefId
        ) else {
            return nil
        }

        if let aiDebrief = await generateWithAI(context: context) {
            return aiDebrief
        }

        return await templateFallback.compose(
            sessionId: sessionId,
            transcriptEntries: transcriptEntries,
            quickAssistCalls: quickAssistCalls,
            coachFindings: coachFindings,
            responseCardEvents: responseCardEvents,
            existingDebriefId: existingDebriefId
        )
    }

    // MARK: - AI Generation

    private func generateWithAI(context: DebriefContext) async -> SessionDebrief? {
        guard let provider = aiProvider else { return nil }

        do {
            let response = try await provider.debrief(context: context)
            return responseParser.parse(
                response: response,
                sessionId: context.sessionId,
                existingDebriefId: context.existingDebriefId
            )
        } catch {
            NSLog("[AISessionDebriefComposer] AI debrief failed, will use template: \(error.localizedDescription)")
            return nil
        }
    }
}
