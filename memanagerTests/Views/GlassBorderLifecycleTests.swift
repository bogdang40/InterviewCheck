import AppKit
import QuartzCore
import XCTest
@testable import memanager

@MainActor
final class GlassBorderLifecycleTests: XCTestCase {
    func testEnablingBorderInVisibleWindowAppliesMotionPolicyAfterLayout() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MEMANAGER_GLASS_NATIVE_LIFECYCLE"] == "1",
                          "Visible Metal lifecycle verification is opt in")
        let workspace = NSWorkspace.shared
        try XCTSkipUnless(!workspace.accessibilityDisplayShouldReduceTransparency
                          && !workspace.accessibilityDisplayShouldIncreaseContrast,
                          "The active accessibility settings use the solid border fallback")
        _ = try await GlassBorderTestResources.prepared()
        let reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        let size = CGSize(width: 400, height: 300)
        let host = NSView(frame: CGRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let border = OverlayGlassBorderView(cornerRadius: 36, inset: 12, style: .none)
        host.addSubview(border)
        border.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            border.topAnchor.constraint(equalTo: host.topAnchor),
            border.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        let window = MaterialPreviewPanel(contentRect: host.frame)
        window.title = "Memanager border lifecycle verification"
        // App content remains painted with None selected. An empty transparent
        // panel does not establish the same WindowServer visibility prerequisite.
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = host
        window.center()
        let originalKeyWindow = NSApp.keyWindow
        let originalFrontmost = workspace.frontmostApplication?.processIdentifier
        window.orderFrontRegardless()
        defer { border.setStyle(.none); window.close() }
        host.layoutSubtreeIfNeeded()
        let visibleDeadline = Date().addingTimeInterval(2)
        while !window.occlusionState.contains(.visible), Date() < visibleDeadline {
            try await waitForAppKit(nanoseconds: 10_000_000)
        }
        guard window.isVisible, window.occlusionState.contains(.visible) else {
            XCTFail("Visible fixture unavailable before renderer creation: "
                + "isVisible=\(window.isVisible), occlusion=\(window.occlusionState.rawValue), "
                + "frame=\(window.frame), screen=\(String(describing: window.screen?.frame)), "
                + "activeSpace=\(window.isOnActiveSpace), appHidden=\(NSApp.isHidden)")
            return
        }
        // Let first-show notifications settle before inserting the renderer.
        try await waitForAppKit(nanoseconds: 100_000_000)

        var retainedRenderer: GlassBorderMetalView?
        for style in [BorderShaderStyle.glass, .liquid] {
            let priorEnabledFrames = border.metalView?.completedFrameCount ?? 0
            border.setStyle(style)
            let metal = try XCTUnwrap(border.metalView)
            if let retainedRenderer { XCTAssertTrue(metal === retainedRenderer) }
            else { retainedRenderer = metal }
            let originalPresentation = metal.onFramePresented
            var lastPresentedRevision: Int?
            var positivePresentations: [(time: TimeInterval, sample: TimeInterval)] = []
            metal.onFramePresented = { timing in
                if timing.presentedTime.isFinite && timing.presentedTime > 0 {
                    XCTAssertTrue(timing.sampledAt.isFinite, "Presented frames must have a finite sample time")
                    if timing.sampledAt.isFinite {
                        positivePresentations.append((timing.presentedTime, timing.sampledAt))
                    }
                }
                if timing.isCurrentGeneration && timing.presentedTime.isFinite && timing.presentedTime > 0 {
                    lastPresentedRevision = timing.configurationRevision
                }
                originalPresentation?(timing)
            }
            defer { metal.onFramePresented = originalPresentation }
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(metal.bounds.size, size)
            XCTAssertEqual(metal.isAnimationRunning, !reduceMotion,
                           "Valid layout must reevaluate the initially zero-sized renderer")
            XCTAssertTrue(metal.isPaused, "MetalKit's unsynchronized internal timer stays disabled")
            XCTAssertFalse(metal.presentsWithTransaction,
                           "Worker command-buffer presentation requires asynchronous layer presentation")
            XCTAssertEqual((metal.layer as? CAMetalLayer)?.maximumDrawableCount, 3)
            XCTAssertFalse(metal.enableSetNeedsDisplay, "Display links and explicit updates own rendering")

            let frameDeadline = Date().addingTimeInterval(2)
            while metal.completedFrameCount == priorEnabledFrames, !metal.hasFailed, Date() < frameDeadline {
                try await waitForAppKit(nanoseconds: 10_000_000)
            }
            XCTAssertFalse(metal.hasFailed)
            XCTAssertGreaterThan(metal.completedFrameCount, priorEnabledFrames)
            let presentedDeadline = Date().addingTimeInterval(2)
            while lastPresentedRevision != metal.configurationRevision, Date() < presentedDeadline {
                try await waitForAppKit(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(lastPresentedRevision, metal.configurationRevision,
                           "GPU completion alone is insufficient; a rendered frame must display")
            // Allow one requested or in-flight frame to settle before measuring.
            try await waitForAppKit(nanoseconds: 100_000_000)
            let settledFrames = metal.completedFrameCount
            try await waitForAppKit(nanoseconds: 200_000_000)
            if reduceMotion {
                XCTAssertEqual(metal.completedFrameCount, settledFrames,
                               "Reduced motion must not run an idle animation loop")
            } else {
                XCTAssertGreaterThan(metal.completedFrameCount, settledFrames,
                                     "Re-enabling the shader must resume actual frame production")
            }
            try await verifyZeroStrengthClearsAndRestores(metal, reduceMotion: reduceMotion)
            if !reduceMotion {
                lastPresentedRevision = nil
                let framesBeforeStaticEdit = metal.completedFrameCount
                metal.configure(cornerRadius: metal.radius, inset: metal.inset, optics: metal.optics,
                                animationEnabled: false, motionSpeed: metal.motionSpeed)
                let staticDeadline = Date().addingTimeInterval(2)
                while lastPresentedRevision != metal.configurationRevision, Date() < staticDeadline {
                    try await waitForAppKit(nanoseconds: 10_000_000)
                }
                XCTAssertFalse(metal.isAnimationRunning)
                XCTAssertEqual(lastPresentedRevision, metal.configurationRevision,
                               "Disabling animation must actually present the latest static frame")
                try await waitForAppKit(nanoseconds: 50_000_000)
                let staticFrames = metal.completedFrameCount
                try await waitForAppKit(nanoseconds: 100_000_000)
                XCTAssertEqual(metal.completedFrameCount, staticFrames, "Static presentation must leave the link idle")
                XCTAssertLessThanOrEqual(staticFrames - framesBeforeStaticEdit, 4,
                    "Waiting for presentation may not submit extra GPU frames beyond bounded retries")
            }
            border.setStyle(.none)
            XCTAssertTrue(metal.isPaused)
            XCTAssertFalse(metal.isAnimationRunning)
            XCTAssertTrue(metal.superview === border)
            XCTAssertTrue(metal.isHidden)
            XCTAssertFalse(metal.enableSetNeedsDisplay)
            let countAtDisable = metal.completedFrameCount
            try await waitForAppKit(nanoseconds: 200_000_000)
            XCTAssertLessThanOrEqual(metal.completedFrameCount, countAtDisable + 1,
                                    "None may finish one admitted frame but must not keep rendering")
            let ordered = positivePresentations.sorted {
                $0.time == $1.time ? $0.sample < $1.sample : $0.time < $1.time
            }
            for (earlier, later) in zip(ordered, ordered.dropFirst()) {
                XCTAssertLessThanOrEqual(earlier.sample, later.sample,
                    "An older targeted frame must not display after a newer urgent update")
            }
        }
        XCTAssertTrue(NSApp.keyWindow === originalKeyWindow)
        XCTAssertEqual(workspace.frontmostApplication?.processIdentifier, originalFrontmost)
    }

    func testPausedDisplayLinkDoesNotRetainItsDetachedView() async throws {
        let resources = try await GlassBorderTestResources.prepared()
        weak var releasedView: GlassBorderMetalView?
        autoreleasepool {
            let view = GlassBorderMetalView(cornerRadius: 36, inset: 12, resources: resources)
            releasedView = view
            XCTAssertTrue(view.isPaused)
            XCTAssertFalse(view.isAnimationRunning)
            view.requestFrame()
            XCTAssertEqual(view.completedFrameCount, 0)
        }
        XCTAssertNil(releasedView, "The retained display-link target must reference its view weakly")
    }

    private func verifyZeroStrengthClearsAndRestores(_ metal: GlassBorderMetalView,
                                                    reduceMotion: Bool) async throws {
        let originalOptics = metal.optics
        let originalCompletion = metal.onFrameCompleted
        let originalPresentation = metal.onFramePresented
        var completedRevision: Int?
        var presentedRevision: Int?
        metal.onFrameCompleted = { timing in
            completedRevision = timing.configurationRevision
            originalCompletion?(timing)
        }
        metal.onFramePresented = { timing in
            if timing.isCurrentGeneration && timing.presentedTime.isFinite && timing.presentedTime > 0 {
                presentedRevision = timing.configurationRevision
            }
            originalPresentation?(timing)
        }
        defer {
            metal.onFrameCompleted = originalCompletion
            metal.onFramePresented = originalPresentation
        }
        var transparentOptics = originalOptics
        transparentOptics.reflectionStrength = 0
        let priorFrames = metal.completedFrameCount
        metal.setOptics(transparentOptics)
        let clearRevision = metal.configurationRevision
        XCTAssertFalse(metal.isAnimationRunning, "A transparent shader must stop continuous frame production")
        XCTAssertTrue(metal.isPaused)
        XCTAssertFalse(metal.enableSetNeedsDisplay)
        let clearDeadline = Date().addingTimeInterval(2)
        while completedRevision != clearRevision || presentedRevision != clearRevision,
              !metal.hasFailed, Date() < clearDeadline {
            try await waitForAppKit(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(metal.hasFailed)
        XCTAssertEqual(completedRevision, clearRevision,
                       "The zero-strength configuration must reach the GPU after any older frame")
        XCTAssertEqual(presentedRevision, clearRevision,
                       "The zero-strength configuration must actually replace the visible rim")
        XCTAssertGreaterThan(metal.completedFrameCount, priorFrames)
        // A frame already in flight may finish before the requested clear frame.
        try await waitForAppKit(nanoseconds: 100_000_000)
        let clearFrames = metal.completedFrameCount
        try await waitForAppKit(nanoseconds: 200_000_000)
        XCTAssertEqual(metal.completedFrameCount, clearFrames,
                       "Zero strength must settle after clearing rather than continue at 30 fps")

        metal.setOptics(originalOptics)
        let restoreRevision = metal.configurationRevision
        XCTAssertEqual(metal.isAnimationRunning, !reduceMotion)
        XCTAssertTrue(metal.isPaused)
        XCTAssertFalse(metal.enableSetNeedsDisplay)
        let restoreDeadline = Date().addingTimeInterval(2)
        while completedRevision != restoreRevision || presentedRevision != restoreRevision,
              !metal.hasFailed, Date() < restoreDeadline {
            try await waitForAppKit(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(metal.hasFailed)
        XCTAssertEqual(completedRevision, restoreRevision)
        XCTAssertEqual(presentedRevision, restoreRevision,
                       "Restoring strength must present the rim after the clear frame")
        XCTAssertGreaterThan(metal.completedFrameCount, clearFrames,
                             "Restoring strength must replace the clear frame with the rim")
        if !reduceMotion {
            let restoredFrames = metal.completedFrameCount
            try await waitForAppKit(nanoseconds: 200_000_000)
            XCTAssertGreaterThan(metal.completedFrameCount, restoredFrames,
                                 "Restored strength must resume continuous animation")
        }
    }

    private func waitForAppKit(nanoseconds: UInt64) async throws {
        let deadline = Date().addingTimeInterval(Double(nanoseconds) / 1_000_000_000)
        repeat {
            pumpAppKitEvents()
            try await Task.sleep(nanoseconds: 1_000_000)
        } while Date() < deadline
    }

    private func pumpAppKitEvents() {
        // XCTest's async waits do not drain the NSEvent queue. WindowServer
        // visibility notifications arrive as AppKit events, so native views
        // remain occluded until AppKit processes them. Leave user input queued.
        let deadline = Date().addingTimeInterval(0.01)
        while let event = NSApp.nextEvent(matching: .appKitDefined, until: deadline,
                                         inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
            if Date() >= deadline { break }
        }
        NSApp.updateWindows()
    }
}
