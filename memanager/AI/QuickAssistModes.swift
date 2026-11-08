import Foundation

/// Where a Quick Assist question came from (used by the question classifier).
enum QuickAssistQuestionSource: String, Codable, Equatable {
    case none
    case manual
    case auto
}

enum QuickAssistContextMode: String, Codable {
    case conversation
    case implementationContext
    case systemDesignContext
    case allSectionsContext
}

enum QuickAssistInteractionMode: String, Codable, CaseIterable {
    case technical
    case behavioural

    var displayName: String {
        switch self {
        case .technical:
            return "Technical"
        case .behavioural:
            return "Behavioural"
        }
    }
}

enum QuickAssistThreadMode: String, Codable, CaseIterable {
    case auto
    case conversation
    case clarify
    case debug
    case walkthrough
    case systemDesign
    case projectBrief
    case behavioural

    var displayName: String {
        switch self {
        case .auto:
            return "Auto"
        case .conversation:
            return "Conversation"
        case .clarify:
            return "Clarify"
        case .debug:
            return "Debug"
        case .walkthrough:
            return "Walkthrough"
        case .systemDesign:
            return "System Design"
        case .projectBrief:
            return "Project Brief"
        case .behavioural:
            return "Behavioural"
        }
    }

    var isBehavioural: Bool {
        self == .behavioural
    }

    var interactionMode: QuickAssistInteractionMode {
        isBehavioural ? .behavioural : .technical
    }

    var preferredIntent: QuickAssistIntent? {
        switch self {
        case .auto, .behavioural:
            return nil
        case .conversation:
            return .conversation
        case .clarify:
            return .clarify
        case .debug:
            return .debug
        case .walkthrough:
            return .walkthrough
        case .systemDesign:
            return .systemDesign
        case .projectBrief:
            return .projectBrief
        }
    }

    init(preferredIntent: QuickAssistIntent?) {
        switch preferredIntent {
        case .conversation:
            self = .conversation
        case .clarify:
            self = .clarify
        case .debug:
            self = .debug
        case .walkthrough:
            self = .walkthrough
        case .systemDesign:
            self = .systemDesign
        case .projectBrief:
            self = .projectBrief
        case nil:
            self = .auto
        }
    }
}

enum QuickAssistIntent: String, Codable {
    case conversation
    case walkthrough
    case systemDesign
    case debug
    case clarify
    case projectBrief

    var displayName: String {
        switch self {
        case .conversation: return "Conversation"
        case .walkthrough: return "Walkthrough"
        case .systemDesign: return "System Design"
        case .debug: return "Debug"
        case .clarify: return "Clarify"
        case .projectBrief: return "Project Brief"
        }
    }
}

enum QuickAssistDetailLevel: String, Codable {
    case concise
    case detailed
}

enum QuickAssistResponseShape: String, Codable {
    case conversational
    case structured
    case implementation
    case architecture
}

enum QuickAssistComplexity: String, Codable {
    case light      // Quick factual answer
    case moderate   // Explain a concept
    case deep       // Walk through architecture/implementation
}

enum QuickAssistModelTier: String, Codable {
    case fast    // Provider's lower-latency Quick Assist model
    case deep    // Provider's primary/deeper reasoning model
}

struct QuickAssistOutputContract: Codable, Equatable {
    let detailLevel: QuickAssistDetailLevel
    let enforceFirstPerson: Bool
    let responseShape: QuickAssistResponseShape
    let requiredElements: [String]

    static let `default` = QuickAssistOutputContract(
        detailLevel: .concise,
        enforceFirstPerson: true,
        responseShape: .conversational,
        requiredElements: []
    )
}
