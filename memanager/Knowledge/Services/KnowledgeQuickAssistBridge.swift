import Foundation

/// Seam between the knowledge graph and Quick Assist: a context block before
/// the turn, optional extraction after it. Extraction runs detached with a
/// minimum spacing so a fast back and forth never fans out into many calls.
@MainActor
final class KnowledgeQuickAssistBridge {
    static let shared = KnowledgeQuickAssistBridge()
    static let minimumExtractionSpacing: TimeInterval = 20
    static let minimumExtractableCharacters = 40

    private let retriever: KnowledgeRetriever
    private let composer: KnowledgeContextComposer
    private let extractorFactory: @Sendable () -> KnowledgeExtractor
    private let settings: SettingsManager
    private var lastExtractionAt: Date?

    init(
        retriever: KnowledgeRetriever = KnowledgeRetriever(),
        composer: KnowledgeContextComposer = KnowledgeContextComposer(),
        extractorFactory: @escaping @Sendable () -> KnowledgeExtractor = { KnowledgeExtractor() },
        settings: SettingsManager = .shared
    ) {
        self.retriever = retriever
        self.composer = composer
        self.extractorFactory = extractorFactory
        self.settings = settings
    }

    func contextBlock(question: String, transcriptTail: String, workspaceID: UUID?) -> String {
        guard settings.knowledgeContextEnabled else { return "" }
        let queryText = [question, transcriptTail].joined(separator: " ")
        let result = retriever.retrieve(KnowledgeRetrievalQuery(text: queryText, workspaceID: workspaceID))
        return composer.compose(result)?.text ?? ""
    }

    /// Schedules extraction for a finished turn. Turns too short to carry
    /// facts never consume the spacing window, and a failed extraction
    /// releases it so the next turn can try again.
    func ingestTurn(question: String, response: String, sourceRef: String, workspace: JobWorkspace?) {
        guard settings.knowledgeAutoExtractEnabled else { return }
        let text = "Question: \(question)\n\nAnswer: \(response)"
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= KnowledgeQuickAssistBridge.minimumExtractableCharacters else { return }
        let now = Date()
        if let lastExtractionAt, now.timeIntervalSince(lastExtractionAt) < KnowledgeQuickAssistBridge.minimumExtractionSpacing { return }
        lastExtractionAt = now

        let workspaceID = workspace?.id
        let workspaceTitle = workspace?.displayTitle
        Task.detached(priority: .utility) { [extractorFactory] in
            let extractor = extractorFactory()
            do {
                let outcome = try await extractor.extractAndMerge(text: text, sourceKind: .session, sourceRef: sourceRef, workspaceID: workspaceID, workspaceTitle: workspaceTitle)
                NSLog("[KnowledgeQuickAssistBridge] merged nodes=%d updated=%d edges=%d", outcome.nodesCreated, outcome.nodesUpdated, outcome.edgesUpserted)
                await KnowledgeGraphStore.shared.noteGraphChanged()
            } catch {
                NSLog("[KnowledgeQuickAssistBridge] extraction failed: %@", error.localizedDescription)
                await self.releaseExtractionWindow(openedAt: now)
            }
        }
    }

    /// Frees the spacing window a failed extraction claimed, but only while
    /// that extraction still owns it; a newer turn's stamp is left alone.
    func releaseExtractionWindow(openedAt: Date) {
        guard lastExtractionAt == openedAt else { return }
        lastExtractionAt = nil
    }
}
