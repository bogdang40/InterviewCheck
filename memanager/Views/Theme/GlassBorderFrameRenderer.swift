import Foundation
import Metal
import QuartzCore

/// Invalidates work that was waiting for a compositor surface when settings,
/// geometry or visibility changed. No UI object is read from the render queue.
final class GlassBorderFrameValidity {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func invalidate() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    func current() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func contains(_ value: UInt64) -> Bool { current() == value }
}

struct GlassBorderFrameRequest {
    let generation: UInt64
    let configurationRevision: Int
    let size: CGSize
    let drawableSize: CGSize
    let radius: CGFloat
    let inset: CGFloat
    let optics: GlassBorderOptics
    let time: Float
    let sampledAt: TimeInterval
    let effectiveSpeed: Double
    let measure: Bool
    var prediction: GlassBorderFramePrediction? = nil

    /// The compositor wait must not make an animated frame older than its
    /// drawable. Subtract uptime in Double before converting the small delta.
    func animationTime(at timestamp: TimeInterval) -> Float {
        guard timestamp.isFinite, sampledAt.isFinite,
              effectiveSpeed.isFinite, effectiveSpeed > 0 else { return time }
        let elapsed = max(0, timestamp - sampledAt) * effectiveSpeed
        let advanced = Double(time) + elapsed
        guard advanced.isFinite, advanced <= Double(Float.greatestFiniteMagnitude) else { return time }
        return Float(advanced)
    }
}

enum GlassBorderFrameOutcome {
    case rendered(GlassBorderFrameTiming?)
    case drawableUnavailable
    case cancelled
    case failed(String)
}

/// Generation validity must be checked when AppKit receives completion, after
/// any configuration change that occurred while the callback was queued.
struct GlassBorderFrameDelivery {
    let validity: GlassBorderFrameValidity
    let generation: UInt64
    let completed: (GlassBorderFrameOutcome) -> Void

    func finish(_ outcome: GlassBorderFrameOutcome) {
        DispatchQueue.main.async {
            completed(validity.contains(generation) ? outcome : .cancelled)
        }
    }
}

/// CAMetalLayer can wait for a free compositor surface for up to a second.
/// Keep that wait and command encoding off the AppKit thread. The owning view
/// admits only one request at a time, so this queue never accumulates frames.
final class GlassBorderFrameRenderer {
    private let queue = DispatchQueue(label: "com.memanager.border-render", qos: .userInteractive)
    private let resources: GlassBorderResources
    let validity = GlassBorderFrameValidity()
    private let presentationTimeline = GlassBorderPresentationTimeline()

    init(resources: GlassBorderResources) { self.resources = resources }

    func render(_ request: GlassBorderFrameRequest, layer: CAMetalLayer,
                presented: ((GlassBorderPresentation) -> Void)?,
                completed: @escaping (GlassBorderFrameOutcome) -> Void) {
        let resources = resources
        let validity = validity
        let timeline = presentationTimeline
        let delivery = GlassBorderFrameDelivery(validity: validity, generation: request.generation,
                                               completed: completed)
        queue.async {
            autoreleasepool {
                guard validity.contains(request.generation) else { delivery.finish(.cancelled); return }
                let started = request.measure ? CACurrentMediaTime() : 0
                guard let drawable = layer.nextDrawable() else { delivery.finish(.drawableUnavailable); return }
                let acquired = CACurrentMediaTime()
                guard validity.contains(request.generation) else {
                    delivery.finish(.cancelled)
                    return
                }
                guard drawable.layer === layer,
                      drawable.texture.width == Int(request.drawableSize.width),
                      drawable.texture.height == Int(request.drawableSize.height) else {
                    delivery.finish(.drawableUnavailable)
                    return
                }
                guard let command = resources.commandQueue.makeCommandBuffer() else {
                    delivery.finish(.failed("Metal could not allocate a glass command buffer."))
                    return
                }
                let predictedTime = timeline.target(for: layer, prediction: request.prediction, now: acquired)
                do {
                    try resources.renderer.encodeBorder(destination: drawable.texture, commandBuffer: command,
                        viewSize: request.size, cornerRadius: request.radius, shoulderWidth: request.inset,
                        optics: request.optics, time: request.animationTime(at: predictedTime))
                    let encoded = request.measure ? CACurrentMediaTime() : 0
                    guard validity.contains(request.generation) else { delivery.finish(.cancelled); return }
                    if let presented {
                        drawable.addPresentedHandler { drawable in
                            let presentedTime = drawable.presentedTime
                            DispatchQueue.main.async {
                                // Instrumentation reports every actual presentation,
                                // including superseded frames and dropped surfaces.
                                presented(GlassBorderPresentation(
                                    configurationRevision: request.configurationRevision,
                                    sampledAt: request.sampledAt, predictedPresentationTime: predictedTime,
                                    presentedTime: presentedTime,
                                    isCurrentGeneration: validity.contains(request.generation)))
                            }
                        }
                    }
                    // CPU submission time; the command queue invokes drawable.present()
                    // after scheduling, so GPU completion is not this deadline.
                    let submittedAt = request.measure ? CACurrentMediaTime() : 0
                    command.addCompletedHandler { command in
                        guard command.status == .completed else {
                            delivery.finish(.failed(command.error?.localizedDescription ?? "Unknown GPU error"))
                            return
                        }
                        let timing = request.measure ? GlassBorderFrameTiming(
                            configurationRevision: request.configurationRevision,
                            sampledAt: request.sampledAt,
                            predictedPresentationTime: predictedTime,
                            drawableMilliseconds: (acquired - started) * 1_000,
                            encodeMilliseconds: (encoded - acquired) * 1_000,
                            gpuMilliseconds: (command.gpuEndTime - command.gpuStartTime) * 1_000,
                            gpuEndTime: command.gpuEndTime,
                            submittedAt: submittedAt,
                            drawableSize: request.drawableSize) : nil
                        delivery.finish(.rendered(timing))
                    }
                    // Commit in queue order with strictly increasing targets. Urgent
                    // work cannot request presentation before a future predecessor.
                    command.present(drawable, atTime: predictedTime)
                    command.commit()
                    timeline.recordCommit(predictedTime, for: layer)
                } catch { delivery.finish(.failed(error.localizedDescription)) }
            }
        }
    }
}
