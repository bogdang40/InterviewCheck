import Foundation

/// One shot extraction: text in, merged graph entries out. Uses the same
/// provider agnostic JSON call the session summary feature already relies on.
final class KnowledgeExtractor {
    private let client: SessionSummaryLLMCalling
    private let merger: KnowledgeGraphMerger
    private let settings: SettingsManager

    init(
        client: SessionSummaryLLMCalling = SessionSummaryLLMClient.shared,
        merger: KnowledgeGraphMerger = KnowledgeGraphMerger(),
        settings: SettingsManager = .shared
    ) {
        self.client = client
        self.merger = merger
        self.settings = settings
    }

    @discardableResult
    func extractAndMerge(
        text: String,
        sourceKind: KnowledgeSourceKind,
        sourceRef: String?,
        workspaceID: UUID?,
        workspaceTitle: String?
    ) async throws -> KnowledgeGraphMerger.Outcome {
        try Task.checkCancellation()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 40 else { return .init() }
        let generation = merger.generation
        let raw = try await client.send(
            systemPrompt: KnowledgeExtractionPrompt.systemPrompt,
            userPrompt: KnowledgeExtractionPrompt.userPrompt(text: trimmed, workspaceTitle: workspaceTitle),
            settings: settings
        )
        try Task.checkCancellation()
        let extracted = KnowledgeExtractionParser.parse(raw)
        guard !extracted.isEmpty else { return .init() }
        return try merger.merge(
            extracted, generation: generation, sourceKind: sourceKind,
            sourceRef: sourceRef, workspaceID: workspaceID
        )
    }
}
