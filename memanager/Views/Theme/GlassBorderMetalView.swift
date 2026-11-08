import AppKit
import MetalKit
import OSLog
import QuartzCore

/// Animates only the transparent rim, without taking input or waiting on the GPU.
final class GlassBorderMetalView: MTKView, MTKViewDelegate {
    private static let logger = Logger(subsystem: "com.memanager.app", category: "GlassBorder")
    private let frameRenderer: GlassBorderFrameRenderer
    private(set) var radius: CGFloat
    private(set) var inset: CGFloat
    private var schedule = GlassBorderRenderSchedule()
    private var drawableRetry = GlassBorderDrawableRetry()
    private var retryWorkItem: DispatchWorkItem?
    private var animationDisplayLink: CADisplayLink?
    private var urgentDrawScheduled = false
    private var animationPrediction: GlassBorderFramePrediction?
    private var latestFrameSampledAt: TimeInterval?
    private var visibilityObserver: NSObjectProtocol?
    private var motionObserver: NSObjectProtocol?
    private var animationClock = GlassBorderAnimationClock()
    private(set) var isAnimationRunning = false
    private var wasRenderable = false
    private(set) var animationEnabled: Bool
    private(set) var motionSpeed: Double
    private var renderingEnabled = true
    private(set) var optics: GlassBorderOptics
    private(set) var hasFailed = false
    private(set) var completedFrameCount = 0
    private(set) var configurationRevision = 0
    var onFailure: (() -> Void)?
    /// Optional instrumentation. Observers receive immutable GPU timings on main.
    var onFrameCompleted: ((GlassBorderFrameTiming) -> Void)?
    var onFramePresented: ((GlassBorderPresentation) -> Void)?
    var onLifecycleEvent: ((GlassBorderLifecycleEvent) -> Void)?

    init(cornerRadius: CGFloat, inset: CGFloat, resources: GlassBorderResources,
          optics: GlassBorderOptics = GlassBorderOptics(),
          animationEnabled: Bool = true, motionSpeed: Double = 1) {
        frameRenderer = GlassBorderFrameRenderer(resources: resources)
        radius = cornerRadius
        self.inset = inset
        self.optics = optics
        self.animationEnabled = animationEnabled
        self.motionSpeed = motionSpeed.isFinite ? max(0, motionSpeed) : 0
        super.init(frame: .zero, device: resources.device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        isPaused = true
        enableSetNeedsDisplay = false
        autoResizeDrawable = true
        layer?.isOpaque = false
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        delegate = self
        guard layer is CAMetalLayer else {
            fail("MetalKit did not create a glass drawable layer.")
            return
        }
        let target = DisplayLinkTarget(view: self)
        let link = displayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        animationDisplayLink = link
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.invalidateFrame()
            self?.updateAnimationState()
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    deinit {
        animationDisplayLink?.invalidate()
        frameRenderer.validity.invalidate()
        retryWorkItem?.cancel()
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
    }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        defer { recordLifecycle(.windowChanged) }
        invalidateFrame()
        if let visibilityObserver {
            NotificationCenter.default.removeObserver(visibilityObserver)
            self.visibilityObserver = nil
        }
        guard let window else {
            updateAnimationState()
            releaseDrawables()
            return
        }
        visibilityObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.invalidateFrame()
            self.updateAnimationState()
            self.recordLifecycle(.occlusionChanged)
            if self.canRender { self.requestFrame() }
            else {
                self.releaseDrawables()
            }
        }
        updateAnimationState()
        requestFrame()
    }

    override func viewDidHide() {
        super.viewDidHide()
        defer { recordLifecycle(.visibilityChanged) }
        invalidateFrame()
        updateAnimationState()
        releaseDrawables()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        defer { recordLifecycle(.visibilityChanged) }
        invalidateFrame()
        updateAnimationState()
    }

    override func layout() {
        super.layout()
        // A renderer added to a visible window starts with zero bounds. Its
        // animation policy can become active only after constraints are laid out.
        updateAnimationState()
    }

    func setOptics(_ optics: GlassBorderOptics) {
        configure(cornerRadius: radius, inset: inset, optics: optics,
                  animationEnabled: animationEnabled, motionSpeed: motionSpeed)
    }

    func configure(cornerRadius: CGFloat, inset: CGFloat, optics: GlassBorderOptics,
                   animationEnabled: Bool, motionSpeed: Double) {
        configurationRevision += 1
        invalidateFrame()
        _ = animationClock.advance(to: CACurrentMediaTime(), isRunning: isAnimationRunning, speed: self.motionSpeed)
        radius = cornerRadius
        self.inset = inset
        self.optics = optics
        self.animationEnabled = animationEnabled
        self.motionSpeed = motionSpeed.isFinite ? max(0, motionSpeed) : 0
        updateAnimationState()
        requestFrame()
    }

    /// None retains the view and pipeline with all frame production disabled.
    /// A late completion cannot restart work while rendering is disabled.
    func setRenderingEnabled(_ enabled: Bool) {
        guard renderingEnabled != enabled else { return }
        _ = animationClock.advance(to: CACurrentMediaTime(), isRunning: isAnimationRunning, speed: motionSpeed)
        invalidateFrame()
        renderingEnabled = enabled
        updateAnimationState()
        if !enabled {
            needsDisplay = false
            releaseDrawables()
        }
    }

    private func updateAnimationState() {
        _ = animationClock.advance(to: CACurrentMediaTime(), isRunning: isAnimationRunning, speed: motionSpeed)
        let visible = canRender
        let becameRenderable = visible && !wasRenderable
        wasRenderable = visible
        let fps = GlassBorderMotionPolicy.framesPerSecond(
            isVisible: visible,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                || !animationEnabled || motionSpeed == 0
                || !GlassBorderMotionPolicy.hasAnimatedContribution(optics))
        isAnimationRunning = fps > 0
        // MetalKit's internal timer stays disabled. CADisplayLink supplies
        // animation timestamps through the common tracking modes.
        if !isPaused { isPaused = true }
        if enableSetNeedsDisplay { enableSetNeedsDisplay = false }
        if !visible {
            animationPrediction = nil
            schedule.cancelUrgentFrame()
        } else if becameRenderable {
            requestFrame()
        }
        updateDisplayLinkState()
    }

    private func updateDisplayLinkState() {
        let running = schedule.shouldRunDisplayLink(isVisible: canRender, isAnimating: isAnimationRunning)
        guard let link = animationDisplayLink, link.isPaused != !running else { return }
        link.isPaused = !running
        recordLifecycle(running ? .linkResumed : .linkPaused)
    }

    private func recordLifecycle(_ kind: GlassBorderLifecycleEvent.Kind, drawableSize: CGSize? = nil) {
        guard let observer = onLifecycleEvent else { return }
        observer(GlassBorderLifecycleEvent(kind: kind, timestamp: CACurrentMediaTime(),
            generation: frameRenderer.validity.current(), configurationRevision: configurationRevision,
            canRender: canRender, isAnimating: isAnimationRunning,
            isHiddenOrHasHiddenAncestor: isHiddenOrHasHiddenAncestor, hasWindow: window != nil,
            windowIsVisible: window?.isVisible == true,
            windowIsOccluded: window?.occlusionState.contains(.visible) == false,
            displayLinkIsPaused: animationDisplayLink?.isPaused ?? true,
            drawableSize: drawableSize ?? self.drawableSize, hasUrgentFramePending: schedule.hasUrgentFramePending,
            isFrameInFlight: schedule.isFrameInFlight))
    }

    private var canRender: Bool {
        renderingEnabled && !hasFailed && !isHiddenOrHasHiddenAncestor && window?.isVisible == true
            && window?.occlusionState.contains(.visible) == true
            && bounds.width > 0 && bounds.height > 0
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        invalidateFrame()
        recordLifecycle(.drawableSizeChanged, drawableSize: size)
        requestFrame()
    }

    /// Coalesce settings and geometry changes after the current native update.
    /// An animation callback may satisfy the pending request first.
    func requestFrame() {
        guard canRender else { return }
        schedule.requestUrgentFrame()
        guard !urgentDrawScheduled else { return }
        urgentDrawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.urgentDrawScheduled = false
            guard self.canRender, self.schedule.hasUrgentFramePending else { return }
            self.draw()
        }
    }

    func draw(in view: MTKView) {
        let requested = schedule.hasUrgentFramePending || animationPrediction != nil
        let prediction = schedule.hasUrgentFramePending ? nil : animationPrediction
        animationPrediction = nil
        guard requested, let metalLayer = layer as? CAMetalLayer,
              schedule.beginFrame(isVisible: canRender) else { return }
        let sampledAt = CACurrentMediaTime()
        latestFrameSampledAt = sampledAt
        let request = GlassBorderFrameRequest(generation: frameRenderer.validity.current(),
            configurationRevision: configurationRevision, size: bounds.size, drawableSize: drawableSize,
            radius: radius, inset: inset, optics: optics,
            time: animationClock.advance(to: sampledAt, isRunning: isAnimationRunning, speed: motionSpeed),
            sampledAt: sampledAt, effectiveSpeed: isAnimationRunning ? motionSpeed : 0,
            measure: onFrameCompleted != nil, prediction: prediction)
        var presentationObserver = onFramePresented
        if !isAnimationRunning {
            let observer = presentationObserver
            let generation = request.generation
            presentationObserver = { [weak self] timing in
                observer?(timing)
                self?.finishStaticPresentation(timing, generation: generation)
            }
        }
        frameRenderer.render(request, layer: metalLayer,
                             presented: presentationObserver) { [weak self] outcome in
            self?.finishFrame(outcome)
        }
    }

    private func finishFrame(_ outcome: GlassBorderFrameOutcome) {
        // Even a stale completion must release the one admitted frame slot.
        let requestedAgain = schedule.finishFrame(isVisible: canRender)
        updateDisplayLinkState()
        switch outcome {
        case .rendered(let timing):
            completedFrameCount += 1
            if isAnimationRunning { resetDrawableRetry() }
            if let timing { onFrameCompleted?(timing) }
        case .failed(let reason):
            fail(reason)
        case .drawableUnavailable:
            if canRender && !isAnimationRunning { retryMissingDrawable() }
            return
        case .cancelled:
            break
        }
        // Urgent changes bypass the next animation tick once the GPU slot clears.
        // Ordinary busy ticks must not become an unpaced completion loop.
        if canRender && (schedule.hasUrgentFramePending || (!isAnimationRunning && requestedAgain)) {
            requestFrame()
        }
    }

    private func finishStaticPresentation(_ timing: GlassBorderPresentation, generation: UInt64) {
        guard timing.isCurrentGeneration, frameRenderer.validity.contains(generation),
              timing.sampledAt == latestFrameSampledAt, canRender, !isAnimationRunning else { return }
        if timing.presentedTime.isFinite && timing.presentedTime > 0 {
            resetDrawableRetry()
        } else if timing.presentedTime == 0 {
            retryMissingDrawable()
        }
    }

    private func invalidateFrame() {
        animationPrediction = nil
        latestFrameSampledAt = nil
        frameRenderer.validity.invalidate()
        resetDrawableRetry()
    }

    private func resetDrawableRetry() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        drawableRetry.reset()
    }

    private func retryMissingDrawable() {
        guard retryWorkItem == nil, let delay = drawableRetry.nextDelay() else { return }
        let generation = frameRenderer.validity.current()
        let retry = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWorkItem = nil
            guard self.frameRenderer.validity.contains(generation), self.canRender, !self.isAnimationRunning else { return }
            self.requestFrame()
        }
        retryWorkItem = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retry)
    }

    private func fail(_ reason: String) {
        guard !hasFailed else { return }
        hasFailed = true
        updateAnimationState()
        Self.logger.error("Glass border rendering failed: \(reason, privacy: .public)")
        onFailure?()
    }

    /// The display link retains its target, which holds the view weakly.
    @MainActor
    private final class DisplayLinkTarget: NSObject {
        weak var view: GlassBorderMetalView?
        init(view: GlassBorderMetalView) { self.view = view }

        @objc func tick(_ link: CADisplayLink) {
            guard let view, view.canRender, view.isAnimationRunning else { return }
            view.animationPrediction = GlassBorderFramePrediction(
                timestamp: link.targetTimestamp, frameInterval: link.targetTimestamp - link.timestamp)
            defer { view.animationPrediction = nil }
            view.draw()
        }
    }
}
