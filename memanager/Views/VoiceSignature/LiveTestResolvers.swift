import CoreGraphics
import Foundation

/// Which tone a recognition score earns against the two thresholds.
enum LiveTestScoreTone {
    static func tone(score: Float, enter: Float, exit: Float) -> OverlayTone {
        if score >= enter { return .success }
        if score >= exit { return .warning }
        return .critical
    }
}

/// How the microphone level reads: too quiet, good, or too loud.
enum VoiceLevelQuality: Equatable {
    case quiet
    case good
    case loud

    static let quietBelow: Float = 0.1
    static let loudAbove: Float = 0.8

    init(level: Float) {
        if level < Self.quietBelow {
            self = .quiet
        } else if level > Self.loudAbove {
            self = .loud
        } else {
            self = .good
        }
    }

    var label: String {
        switch self {
        case .quiet: return "Too quiet"
        case .good: return "Good"
        case .loud: return "Too loud"
        }
    }

    var tone: OverlayTone {
        switch self {
        case .quiet: return .warning
        case .good: return .success
        case .loud: return .critical
        }
    }
}

/// Geometry of the half circle gauge: the arc runs from the left end
/// (score 0) over the top to the right end (score 1).
enum LiveTestGaugeGeometry {
    static let arcStart: CGFloat = 0.25
    static let arcLength: CGFloat = 0.5

    static func arcEnd(for score: Float) -> CGFloat {
        arcStart + arcLength * CGFloat(min(max(score, 0), 1))
    }

    /// Offset of a threshold marker from the gauge centre.
    static func markerOffset(value: Float, radius: CGFloat) -> CGPoint {
        let degrees = 180 + Double(min(max(value, 0), 1)) * 180
        let radians = degrees * .pi / 180
        return CGPoint(x: radius * cos(radians), y: radius * sin(radians))
    }
}

/// Fixed length score history for the chart.
struct ScoreHistory: Equatable {
    let capacity: Int
    private(set) var scores: [Float] = []

    init(capacity: Int = 50, scores: [Float] = []) {
        self.capacity = capacity
        self.scores = Array(scores.suffix(capacity))
    }

    mutating func append(_ score: Float) {
        scores.append(score)
        if scores.count > capacity {
            scores.removeFirst(scores.count - capacity)
        }
    }

    mutating func removeAll() {
        scores.removeAll()
    }
}
