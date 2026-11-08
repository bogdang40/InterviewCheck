import AppKit

enum OverlayPresentationIntent {
    case viewing
    case keyboardInput
}

/// Window operations are the boundary between viewing an answer and taking input.
@MainActor
protocol OverlayWindowPresenting: AnyObject {
    func orderFront(_ sender: Any?)
    func makeKeyAndOrderFront(_ sender: Any?)
    @discardableResult func makeFirstResponder(_ responder: NSResponder?) -> Bool
    func orderOut(_ sender: Any?)
}

extension OverlayWindow: OverlayWindowPresenting {}

@MainActor
struct OverlayWindowPresentation {
    let window: any OverlayWindowPresenting

    func show(intent: OverlayPresentationIntent = .viewing) {
        switch intent {
        case .viewing:
            window.orderFront(nil)
        case .keyboardInput:
            window.makeKeyAndOrderFront(nil)
        }
    }

    func hide() {
        window.makeFirstResponder(nil)
        window.orderOut(nil)
    }
}
