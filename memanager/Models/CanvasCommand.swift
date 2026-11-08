import Foundation

/// DSL v0 commands the LLM can emit inline to drive the Live Reasoning
/// Canvas. Each command is line-oriented and fenced with a subtype marker
/// (for example: ```canvas:array). The parser lifts commands out of the
/// stream; what remains is prose the streaming text view renders unchanged.
///
/// Intentionally flat (no nesting past one level) so the decoder stays a
/// 200-line state machine and so the model can emit them reliably from a
/// short few-shot block in the system prompt.
enum CanvasCommand: Equatable {
    case array(CanvasArrayPayload)
    case window(CanvasWindowPayload)
    case pointer(CanvasPointerPayload)
    case highlight(CanvasHighlightPayload)
    case clear(sceneID: String)
}

struct CanvasArrayPayload: Equatable {
    let id: String
    let values: [String]
    let label: String?
}

struct CanvasWindowPayload: Equatable {
    let targetID: String
    let op: Op
    let left: Int
    let right: Int

    enum Op: String {
        case set
        case expandRight = "expand_right"
        case shrinkLeft = "shrink_left"
    }
}

struct CanvasPointerPayload: Equatable {
    let id: String
    let targetID: String
    let op: Op
    let name: String
    let index: Int

    enum Op: String {
        case set
        case advance
        case retreat
    }
}

struct CanvasHighlightPayload: Equatable {
    let targetID: String
    let kind: Kind
    let value: String
    let ttlMs: Int

    var identity: Identity {
        Identity(targetID: targetID, kind: kind, value: value)
    }

    struct Identity: Hashable {
        let targetID: String
        let kind: Kind
        let value: String
    }

    enum Kind: String {
        case indices
        case cell
        case node
        case edge
    }
}
