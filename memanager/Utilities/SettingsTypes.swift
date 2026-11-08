import Foundation

struct QuickAssistPrompt: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var prompt: String

    init(id: UUID = UUID(), title: String, prompt: String) {
        self.id = id
        self.title = title
        self.prompt = prompt
    }
}

struct ResolvedQuickAssistPrompt: Equatable {
    enum Status: Equatable {
        case empty
        case ignoredIrrelevant
        case applied
        case truncatedApplied
    }

    let text: String
    let status: Status
    let originalLength: Int
    let appliedLength: Int

    var statusMessage: String? {
        switch status {
        case .empty, .applied:
            return nil
        case .ignoredIrrelevant:
            return "Custom Quick Assist prompt ignored because it was not relevant to this question."
        case .truncatedApplied:
            return "Custom Quick Assist prompt applied with truncation (\(appliedLength)/\(originalLength) chars)."
        }
    }
}

enum OverlayAnchorEdge: String, Codable {
    case left
    case right
}

enum OpenAIQuickAssistDisplayMode: String, CaseIterable, Codable {
    case response
    case guarded
}

/// Programming languages for code solutions
enum ProgrammingLanguage: String, CaseIterable, Codable {
    case python = "Python"
    case cpp = "C++"
    case java = "Java"
    case javascript = "JavaScript"
    case typescript = "TypeScript"
    case go = "Go"
    case rust = "Rust"
    case csharp = "C#"
    case swift = "Swift"
    case kotlin = "Kotlin"
    
    /// The language identifier for code blocks (e.g., ```cpp)
    var codeBlockIdentifier: String {
        switch self {
        case .python: return "python"
        case .cpp: return "cpp"
        case .java: return "java"
        case .javascript: return "javascript"
        case .typescript: return "typescript"
        case .go: return "go"
        case .rust: return "rust"
        case .csharp: return "csharp"
        case .swift: return "swift"
        case .kotlin: return "kotlin"
        }
    }
}
