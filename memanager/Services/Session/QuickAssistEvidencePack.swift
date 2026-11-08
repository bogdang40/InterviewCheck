import Foundation

struct QuickAssistEvidencePack {
    let contextMode: QuickAssistContextMode
    let modelTier: QuickAssistModelTier
    let questionSource: QuickAssistQuestionSource
    let transcriptLength: Int
    let questionLength: Int
    let extraContextLength: Int
    let relatedMemoryCount: Int
    let screenshotCount: Int
    let routeConfidence: Double
    let routeReason: String
    let routeOverrideIntent: QuickAssistIntent?

    var manifest: String {
        [
            "context_mode=\(contextMode.rawValue)",
            "model_tier=\(modelTier.rawValue)",
            "question_source=\(questionSource.rawValue)",
            "transcript_len=\(transcriptLength)",
            "question_len=\(questionLength)",
            "extra_context_len=\(extraContextLength)",
            "related_memory_count=\(relatedMemoryCount)",
            "screenshot_count=\(screenshotCount)",
            "route_confidence=\(String(format: "%.2f", routeConfidence))",
            "route_override=\(routeOverrideIntent?.rawValue ?? "none")",
            "route_reason=\(routeReason)"
        ].joined(separator: "\n")
    }
}

protocol QuickAssistEvidencePackBuilding {
    func build(
        contextMode: QuickAssistContextMode,
        modelTier: QuickAssistModelTier,
        questionSource: QuickAssistQuestionSource,
        transcript: String,
        question: String,
        extraContext: String,
        relatedMemorySnippets: [String],
        screenshotCount: Int,
        routeConfidence: Double,
        routeReason: String,
        routeOverrideIntent: QuickAssistIntent?
    ) -> QuickAssistEvidencePack
}

final class QuickAssistEvidencePackBuilder: QuickAssistEvidencePackBuilding {
    func build(
        contextMode: QuickAssistContextMode,
        modelTier: QuickAssistModelTier,
        questionSource: QuickAssistQuestionSource,
        transcript: String,
        question: String,
        extraContext: String,
        relatedMemorySnippets: [String],
        screenshotCount: Int,
        routeConfidence: Double,
        routeReason: String,
        routeOverrideIntent: QuickAssistIntent?
    ) -> QuickAssistEvidencePack {
        QuickAssistEvidencePack(
            contextMode: contextMode,
            modelTier: modelTier,
            questionSource: questionSource,
            transcriptLength: transcript.trimmingCharacters(in: .whitespacesAndNewlines).count,
            questionLength: question.trimmingCharacters(in: .whitespacesAndNewlines).count,
            extraContextLength: extraContext.trimmingCharacters(in: .whitespacesAndNewlines).count,
            relatedMemoryCount: relatedMemorySnippets.count,
            screenshotCount: screenshotCount,
            routeConfidence: routeConfidence,
            routeReason: routeReason,
            routeOverrideIntent: routeOverrideIntent
        )
    }
}
