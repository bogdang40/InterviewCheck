import Foundation

/// Aggregated scene state that the UI reads. Immutable value type; the
/// `CanvasDirector` rebuilds a new scene on every command so SwiftUI diffing
/// stays cheap. `isNonEmpty` drives whether the canvas pane is presented.
struct CanvasScene: Equatable {
    var arrays: [String: CanvasArrayPayload]
    var windows: [String: CanvasWindowPayload]
    var pointers: [String: CanvasPointerPayload]
    var highlights: [CanvasHighlightPayload]

    static let empty = CanvasScene(
        arrays: [:],
        windows: [:],
        pointers: [:],
        highlights: []
    )

    var isNonEmpty: Bool {
        !arrays.isEmpty || !windows.isEmpty || !pointers.isEmpty || !highlights.isEmpty
    }

    /// Non-mutating helpers so callers can rebuild in a functional style.

    func applying(_ command: CanvasCommand) -> CanvasScene {
        var next = self
        next.apply(command)
        return next
    }

    mutating func apply(_ command: CanvasCommand) {
        switch command {
        case .array(let payload):
            arrays[payload.id] = payload
        case .window(let payload):
            windows[payload.targetID] = payload
        case .pointer(let payload):
            pointers[payload.id] = payload
        case .highlight(let payload):
            highlights.removeAll { $0.identity == payload.identity }
            highlights.append(payload)
        case .clear(let sceneID):
            arrays.removeValue(forKey: sceneID)
            windows.removeValue(forKey: sceneID)
            pointers = pointers.filter { $0.value.targetID != sceneID }
            highlights.removeAll { $0.targetID == sceneID }
        }
    }
}
