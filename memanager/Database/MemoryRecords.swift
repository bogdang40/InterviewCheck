import Foundation

enum MemoryNodeSource: String {
    case solve
    case quickAssist = "quick_assist"
    case systemDesign = "system_design"
    case debrief
}

enum MemoryRelationType: String {
    case followUp = "follow_up"
    case supportsAnswer = "supports_answer"
    case threadContinuation = "thread_continuation"
}

struct MemoryNodeRecord: Identifiable {
    let id: String
    let sessionId: String
    let sourceType: MemoryNodeSource
    let sourceRef: String?
    let threadId: String?
    let turnId: String?
    let questionSource: QuickAssistQuestionSource?
    let intent: String?
    let contextMode: String?
    let content: String
    let summary: String?
    let tags: [String]
    let importance: Int
    let createdAt: Date
    let updatedAt: Date

    init(
        id: String,
        sessionId: String,
        sourceType: MemoryNodeSource,
        sourceRef: String?,
        threadId: String? = nil,
        turnId: String? = nil,
        questionSource: QuickAssistQuestionSource? = nil,
        intent: String? = nil,
        contextMode: String? = nil,
        content: String,
        summary: String?,
        tags: [String],
        importance: Int,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.sessionId = sessionId
        self.sourceType = sourceType
        self.sourceRef = sourceRef
        self.threadId = threadId
        self.turnId = turnId
        self.questionSource = questionSource
        self.intent = intent
        self.contextMode = contextMode
        self.content = content
        self.summary = summary
        self.tags = tags
        self.importance = importance
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct MemoryRelationshipRecord {
    let fromNodeId: String
    let toNodeId: String
    let relationType: MemoryRelationType
    let strength: Int
    let createdAt: Date
}

struct MemorySearchHit {
    let node: MemoryNodeRecord
    let score: Double
}

enum RelatedMemoryQuerySource: String, Codable {
    case manualQuestion = "manual_question"
    case autoSideQuestion = "auto_side_question"
    case followUp = "follow_up"
    case threadNavigation = "thread_navigation"
    case turnSelection = "turn_selection"
    case quickAssistView = "quick_assist_view"
}

enum RelatedMemoryReason: String, Codable {
    case lexicalAnchor = "lexical_anchor"
    case lexicalExpansion = "lexical_expansion"
    case relationshipHop = "relationship_hop"
    case threadMatch = "thread_match"
    case questionSourceMatch = "question_source_match"
    case intentMatch = "intent_match"
    case contextModeMatch = "context_mode_match"
    case recencyBoost = "recency_boost"
    case importanceBoost = "importance_boost"
}

struct RelatedMemoryQuery {
    let text: String
    let querySource: RelatedMemoryQuerySource
    let sessionId: String?
    let threadId: String?
    let turnId: String?
    let questionSource: QuickAssistQuestionSource?
    let intent: QuickAssistIntent?
    let contextMode: QuickAssistContextMode?
    let excludedNodeIds: [String]
    let maxGraphHops: Int
    let anchorLimit: Int
    let expansionLimit: Int

    init(
        text: String,
        querySource: RelatedMemoryQuerySource,
        sessionId: String? = nil,
        threadId: String? = nil,
        turnId: String? = nil,
        questionSource: QuickAssistQuestionSource? = nil,
        intent: QuickAssistIntent? = nil,
        contextMode: QuickAssistContextMode? = nil,
        excludedNodeIds: [String] = [],
        maxGraphHops: Int = 1,
        anchorLimit: Int = 16,
        expansionLimit: Int = 28
    ) {
        self.text = text
        self.querySource = querySource
        self.sessionId = sessionId
        self.threadId = threadId
        self.turnId = turnId
        self.questionSource = questionSource
        self.intent = intent
        self.contextMode = contextMode
        self.excludedNodeIds = excludedNodeIds
        self.maxGraphHops = max(0, maxGraphHops)
        self.anchorLimit = max(1, anchorLimit)
        self.expansionLimit = max(1, expansionLimit)
    }
}

struct RelatedMemorySnippet: Identifiable, Equatable {
    let id: String
    let text: String
    let sourceType: MemoryNodeSource
    let sourceRef: String?
    let threadId: String?
    let turnId: String?
    let score: Double
    let reasons: [RelatedMemoryReason]
    let relationType: MemoryRelationType?
    let isPinned: Bool

    func withPinned(_ pinned: Bool) -> RelatedMemorySnippet {
        RelatedMemorySnippet(
            id: id,
            text: text,
            sourceType: sourceType,
            sourceRef: sourceRef,
            threadId: threadId,
            turnId: turnId,
            score: score,
            reasons: reasons,
            relationType: relationType,
            isPinned: pinned
        )
    }
}

struct RelatedMemoryResult: Equatable {
    let snippets: [RelatedMemorySnippet]
    let queryTokens: [String]
    let confidence: Double
    let latencyMs: Int
    let diagnostics: String

    static let empty = RelatedMemoryResult(
        snippets: [],
        queryTokens: [],
        confidence: 0,
        latencyMs: 0,
        diagnostics: "empty"
    )
}

struct MemoryRetrievalEventRecord {
    let querySource: RelatedMemoryQuerySource
    let queryText: String
    let queryTokens: [String]
    let anchorQuery: String?
    let expansionQuery: String?
    let hitCount: Int
    let topNodeIds: [String]
    let topScore: Double
    let confidence: Double
    let latencyMs: Int
    let sessionId: String?
    let threadId: String?
    let turnId: String?
    let createdAt: Date

    init(
        querySource: RelatedMemoryQuerySource,
        queryText: String,
        queryTokens: [String],
        anchorQuery: String?,
        expansionQuery: String?,
        hitCount: Int,
        topNodeIds: [String],
        topScore: Double,
        confidence: Double,
        latencyMs: Int,
        sessionId: String?,
        threadId: String?,
        turnId: String?,
        createdAt: Date = Date()
    ) {
        self.querySource = querySource
        self.queryText = queryText
        self.queryTokens = queryTokens
        self.anchorQuery = anchorQuery
        self.expansionQuery = expansionQuery
        self.hitCount = hitCount
        self.topNodeIds = topNodeIds
        self.topScore = topScore
        self.confidence = confidence
        self.latencyMs = latencyMs
        self.sessionId = sessionId
        self.threadId = threadId
        self.turnId = turnId
        self.createdAt = createdAt
    }
}

// MARK: - Workstream Timeline
