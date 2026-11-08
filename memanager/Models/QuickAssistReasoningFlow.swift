import Foundation

/// A single deliberate beat inside the model's train of thought. Thoughts land
/// between tool invocations, letting the model narrate intent before acting.
struct QuickAssistFlowThought: Identifiable, Equatable {
    let id: String
    let iteration: Int
    let text: String
    let precedesToolCallID: String?

    init(
        id: String = UUID().uuidString,
        iteration: Int,
        text: String,
        precedesToolCallID: String? = nil
    ) {
        self.id = id
        self.iteration = iteration
        self.text = text
        self.precedesToolCallID = precedesToolCallID
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A step inside the model's reasoning: either a narrated thought or a
/// concrete tool action. Rendered in sequence to create the "flow" UI.
enum QuickAssistFlowStep: Identifiable, Equatable {
    case thought(QuickAssistFlowThought)
    case toolCall(QuickAssistToolTraceStep)

    var id: String {
        switch self {
        case .thought(let thought): return "thought::" + thought.id
        case .toolCall(let step): return "tool::" + step.id
        }
    }

    var iteration: Int {
        switch self {
        case .thought(let thought): return thought.iteration
        case .toolCall(let step): return step.iteration
        }
    }

    static func == (lhs: QuickAssistFlowStep, rhs: QuickAssistFlowStep) -> Bool {
        switch (lhs, rhs) {
        case (.thought(let lhsThought), .thought(let rhsThought)):
            return lhsThought == rhsThought
        case (.toolCall(let lhsStep), .toolCall(let rhsStep)):
            return lhsStep == rhsStep
        default:
            return false
        }
    }
}

/// The complete reasoning journey for a single assistant turn. Carries both the
/// interleaved thought and tool sequence and the original tool trace so older
/// views (evidence manifest, reviewer) can keep working unchanged.
struct QuickAssistReasoningFlow: Equatable {
    let turnID: UUID?
    let steps: [QuickAssistFlowStep]
    let trace: QuickAssistToolTrace

    var isEmpty: Bool {
        steps.isEmpty
    }

    var hasThoughts: Bool {
        steps.contains { step in
            if case .thought(let thought) = step { return !thought.isEmpty }
            return false
        }
    }

    var hasToolCalls: Bool {
        steps.contains { step in
            if case .toolCall = step { return true }
            return false
        }
    }

    var toolStepCount: Int {
        steps.reduce(into: 0) { accumulator, step in
            if case .toolCall = step { accumulator += 1 }
        }
    }

    var statusSummary: String {
        trace.statusSummary
    }

    static let empty = QuickAssistReasoningFlow(
        turnID: nil,
        steps: [],
        trace: QuickAssistToolTrace(turnID: nil, steps: [])
    )
}
