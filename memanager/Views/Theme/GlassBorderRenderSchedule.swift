/// Main-thread scheduling state. Repeated invalidations while the GPU is busy
/// collapse into one later frame; completion alone never starts an idle loop.
struct GlassBorderRenderSchedule {
    private(set) var isFrameInFlight = false
    private(set) var hasUrgentFramePending = false
    private var redrawPending = false

    func shouldRunDisplayLink(isVisible: Bool, isAnimating: Bool) -> Bool {
        isVisible && isAnimating
    }

    mutating func requestUrgentFrame() { hasUrgentFramePending = true }
    mutating func cancelUrgentFrame() { hasUrgentFramePending = false }

    mutating func beginFrame(isVisible: Bool) -> Bool {
        guard isVisible else {
            redrawPending = false
            hasUrgentFramePending = false
            return false
        }
        guard !isFrameInFlight else {
            redrawPending = true
            return false
        }
        isFrameInFlight = true
        hasUrgentFramePending = false
        return true
    }

    /// The caller invalidates its view only when a newer frame was requested.
    mutating func finishFrame(isVisible: Bool) -> Bool {
        guard isFrameInFlight else { return false }
        isFrameInFlight = false
        let shouldRedraw = isVisible && redrawPending
        redrawPending = false
        if !isVisible { hasUrgentFramePending = false }
        return shouldRedraw
    }
}

/// Motion stops when hidden or when the user requests reduced motion.
enum GlassBorderMotionPolicy {
    static func hasAnimatedContribution(_ optics: GlassBorderOptics) -> Bool {
        optics.reflectionStrength > 0 && optics.thickness > 0
            && (optics.ior > 1 || optics.dispersion > 0)
            && (optics.gooey > 0 || optics.lightMotion > 0 || optics.liquid > 0)
    }

    static func framesPerSecond(isVisible: Bool, reduceMotion: Bool) -> Int {
        isVisible && !reduceMotion ? 30 : 0
    }
}
