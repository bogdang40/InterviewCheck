import Foundation

// MARK: - Problem Section

struct ProblemContent {
    let restatement: String?
    let constraints: [Constraint]
    let insight: String?
    let correctnessProof: String?  // "Why this approach is correct" section
    let rawContent: String

    var isEmpty: Bool {
        let hasRestatement = restatement?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasInsight = insight?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasProof = correctnessProof?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return !hasRestatement && constraints.isEmpty && !hasInsight && !hasProof
    }
    
    /// Check if we have any meaningful structured content to display
    var hasStructuredContent: Bool {
        let hasRestatement = restatement?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasInsight = insight?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasProof = correctnessProof?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return hasRestatement || !constraints.isEmpty || hasInsight || hasProof
    }
}

struct Constraint: Identifiable {
    let id = UUID()
    let type: ConstraintType
    let description: String

    enum ConstraintType: String, CaseIterable {
        case time = "Time"
        case space = "Space"
        case input = "Input"
        case output = "Output"

        var icon: String {
            switch self {
            case .time: return "clock"
            case .space: return "memorychip"
            case .input: return "arrow.right.circle"
            case .output: return "arrow.left.circle"
            }
        }
    }
}

// MARK: - Clarifying Questions Section

struct QuestionsContent {
    let edgeCaseQuestions: [Question]
    let constraintQuestions: [Question]
    let validationQuestions: [Question]
    let rawContent: String

    var isEmpty: Bool {
        edgeCaseQuestions.isEmpty && constraintQuestions.isEmpty && validationQuestions.isEmpty
    }

    var allQuestions: [Question] {
        edgeCaseQuestions + constraintQuestions + validationQuestions
    }
}

struct Question: Identifiable {
    let id = UUID()
    let text: String
    let assumption: String?
    let category: QuestionCategory

    enum QuestionCategory: String {
        case edgeCase = "Edge Cases"
        case constraint = "Constraints"
        case validation = "Input Validation"

        var icon: String {
            switch self {
            case .edgeCase: return "exclamationmark.triangle"
            case .constraint: return "ruler"
            case .validation: return "checkmark.shield"
            }
        }
    }
}

// MARK: - Implementation Section (Unified Approach + Code)

/// A step that contains BOTH reasoning AND cumulative code
struct ImplementationStep: Identifiable {
    let id = UUID()
    let number: Int
    let title: String                       // Short title: "Track character positions"
    let reasoning: String                   // The thinking before/during code
    let codeSnippet: String                 // Just this step's NEW code
    let cumulativeCode: String              // All code up to and including this step
    let language: String                    // Programming language
    let addedLineRange: ClosedRange<Int>?   // Which lines are new (for highlighting)
}

/// The complete implementation content (replaces separate Approach + Code sections)
struct ImplementationContent {
    let steps: [ImplementationStep]
    let language: String
    let rawContent: String

    var isEmpty: Bool {
        steps.isEmpty && rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    /// Check if we have parsed step content (vs just raw content)
    var hasStructuredSteps: Bool {
        !steps.isEmpty
    }
    
    /// Check if we have any content at all
    var hasContent: Bool {
        !steps.isEmpty || !rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Get the final complete code (from the last step)
    var finalCode: String {
        steps.last?.cumulativeCode ?? ""
    }

    /// Get cumulative code up to and including a specific step
    func cumulativeCode(throughStep stepNumber: Int) -> String {
        guard let step = steps.first(where: { $0.number == stepNumber }) else {
            return ""
        }
        return step.cumulativeCode
    }
}

// MARK: - Tests Section

struct TestsContent {
    let baseCases: [TestCase]
    let edgeCases: [TestCase]
    let errorCases: [TestCase]
    let rawContent: String

    var isEmpty: Bool {
        baseCases.isEmpty && edgeCases.isEmpty && errorCases.isEmpty
    }

    var allCases: [TestCase] {
        baseCases + edgeCases + errorCases
    }
}

struct TestCase: Identifiable {
    let id = UUID()
    let input: String
    let expected: String
    let reasoning: String?
    let category: TestCategory

    enum TestCategory: String {
        case base = "Base"
        case edge = "Edge"
        case error = "Error"

        var icon: String {
            switch self {
            case .base: return "checkmark.circle"
            case .edge: return "exclamationmark.triangle"
            case .error: return "xmark.octagon"
            }
        }
    }
}

// MARK: - Complexity Section

struct ComplexityContent {
    let time: ComplexityAnalysis?
    let space: ComplexityAnalysis?
    let tradeOff: String?
    let rawContent: String

    var isEmpty: Bool {
        time == nil && space == nil
    }
}

struct ComplexityAnalysis: Identifiable {
    let id = UUID()
    let notation: String
    let breakdown: String
    let type: ComplexityType

    enum ComplexityType: String {
        case time = "Time"
        case space = "Space"

        var icon: String {
            switch self {
            case .time: return "clock"
            case .space: return "memorychip"
            }
        }
    }
}

// MARK: - System Design Section

/// Content for a system design question response
