import CoreGraphics

/// Zoom limits for the adaptive diagram wrapper, kept pure so the clamp,
/// the step, and the percent label can be tested without a view.
enum MermaidZoomPolicy {
    static let minimum: CGFloat = 0.7
    static let maximum: CGFloat = 2.0
    static let increment: CGFloat = 0.15
    static let reset: CGFloat = 1.0

    static func clamp(_ value: CGFloat) -> CGFloat {
        max(minimum, min(maximum, value))
    }

    static func zoomedIn(_ value: CGFloat) -> CGFloat {
        clamp(value + increment)
    }

    static func zoomedOut(_ value: CGFloat) -> CGFloat {
        clamp(value - increment)
    }

    static func canZoomIn(_ value: CGFloat) -> Bool {
        value < maximum - 0.001
    }

    static func canZoomOut(_ value: CGFloat) -> Bool {
        value > minimum + 0.001
    }

    static func percent(_ value: CGFloat) -> Int {
        Int((value * 100).rounded())
    }

    static func percentLabel(_ value: CGFloat) -> String {
        "\(percent(value))%"
    }
}
