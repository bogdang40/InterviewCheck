import Foundation

struct GlassBorderFrameTiming {
    let configurationRevision: Int
    let sampledAt: TimeInterval
    /// Selected absolute presentation target, also used for animation phase.
    let predictedPresentationTime: TimeInterval
    let drawableMilliseconds: Double
    let encodeMilliseconds: Double
    let gpuMilliseconds: Double
    let gpuEndTime: TimeInterval
    let submittedAt: TimeInterval
    let drawableSize: CGSize
}

struct GlassBorderPresentation {
    let configurationRevision: Int
    let sampledAt: TimeInterval
    /// Selected absolute presentation target, also used for animation phase.
    let predictedPresentationTime: TimeInterval
    let presentedTime: TimeInterval
    let isCurrentGeneration: Bool
}

/// Optional lifecycle instrumentation. Events describe native state changes,
/// never a per-frame stream, and contain no user content.
struct GlassBorderLifecycleEvent {
    enum Kind: String {
        case linkPaused, linkResumed, windowChanged, visibilityChanged, occlusionChanged, drawableSizeChanged
    }

    let kind: Kind
    let timestamp: TimeInterval
    let generation: UInt64
    let configurationRevision: Int
    let canRender: Bool
    let isAnimating: Bool
    let isHiddenOrHasHiddenAncestor: Bool
    let hasWindow: Bool
    let windowIsVisible: Bool
    let windowIsOccluded: Bool
    let displayLinkIsPaused: Bool
    let drawableSize: CGSize
    let hasUrgentFramePending: Bool
    let isFrameInFlight: Bool
}
