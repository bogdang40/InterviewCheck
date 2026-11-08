import CoreGraphics
import Foundation

/// Window-relative staging; the Blender frames contain poses, not screen travel.
struct AbleyWelcomeMotion {
    static let duration = 4.3
    static let stillDuration = 1.2
    static let framesPerSecond = 30.0
    static let frameCount = 120
    static let dockSize: CGFloat = 32

    let elapsed: TimeInterval
    let size: CGSize
    var reduceMotion = false
    var borderWidth: CGFloat = 0

    static func dockCenter(in size: CGSize, borderWidth: CGFloat = 0) -> CGPoint {
        FloatingShellGeometry(size: size, borderWidth: borderWidth).brandCenter
    }

    static func frameIndex(at elapsed: TimeInterval) -> Int {
        guard elapsed.isFinite else { return 0 }
        let time = min(Double(frameCount - 1) / framesPerSecond, max(0, elapsed))
        return min(frameCount - 1, Int(floor(time * framesPerSecond)))
    }

    private var travel: Double { reduceMotion ? 0 : smooth(from: 1.9, to: 4.0) }
    private var heroSize: CGFloat { max(32, min(size.width * 0.96, size.height * 0.74)) }

    var characterSize: CGFloat {
        heroSize * CGFloat(pow(Double(Self.dockSize / heroSize), travel))
    }

    var center: CGPoint {
        let start = CGPoint(x: size.width / 2, y: size.height * 0.54)
        let end = Self.dockCenter(in: size, borderWidth: borderWidth)
        let c1 = CGPoint(x: start.x - size.width * 0.18, y: start.y)
        let c2 = CGPoint(x: end.x, y: max(end.y, size.height * 0.30))
        let t = CGFloat(travel)
        let u = 1 - t
        return CGPoint(x: u*u*u*start.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*end.x,
                       y: u*u*u*start.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*end.y)
    }

    var greetingOpacity: Double { reduceMotion ? 1 : 1 - smooth(from: 1.3, to: 1.75) }
    var backdropOpacity: Double { reduceMotion ? 1 : 1 - smooth(from: 2.35, to: 3.8) }
    var iconOpacity: Double { reduceMotion ? 0 : smooth(from: 3.95, to: Self.duration) }

    private func smooth(from start: Double, to end: Double) -> Double {
        let value = elapsed.isFinite ? elapsed : 0
        let t = min(1, max(0, (value - start) / (end - start)))
        return t * t * (3 - 2 * t)
    }
}
