import Foundation

/// An ordered fragment of an assistant turn. Preserving text to tool order lets
/// the UI weave the model's thinking voice between tool invocations, so the
/// experience feels like a guided train of thought rather than a silent batch
/// of tool results.
enum ProjectToolLoopContentBlock: Equatable {
    case text(String)
    case toolCall(ToolCall)

    static func == (lhs: ProjectToolLoopContentBlock, rhs: ProjectToolLoopContentBlock) -> Bool {
        switch (lhs, rhs) {
        case (.text(let leftText), .text(let rightText)):
            return leftText == rightText
        case (.toolCall(let leftCall), .toolCall(let rightCall)):
            return leftCall.id == rightCall.id
                && leftCall.name == rightCall.name
        default:
            return false
        }
    }

    var isText: Bool {
        if case .text = self { return true }
        return false
    }

    var textValue: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    var toolCall: ToolCall? {
        if case .toolCall(let call) = self { return call }
        return nil
    }
}

/// Minimal description of a thought surface emitted by the model during a turn.
/// A thought is any text block that appears alongside or in between tool calls;
/// it carries the rationale that turns a tool invocation into a deliberate step.
struct ProjectToolLoopThought: Identifiable, Equatable {
    let id: String
    let iteration: Int
    let text: String
    let precedesCallID: String?

    init(
        id: String = UUID().uuidString,
        iteration: Int,
        text: String,
        precedesCallID: String?
    ) {
        self.id = id
        self.iteration = iteration
        self.text = text
        self.precedesCallID = precedesCallID
    }
}
