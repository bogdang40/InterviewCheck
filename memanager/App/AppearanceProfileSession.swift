import AppKit
import Combine
import OSLog
import QuartzCore
import SwiftUI

/// Runs the production appearance surface in an ordinary, inspectable window.
/// Both launch gates are required so its settings and storage are isolated.
@MainActor
final class AppearanceProfileSession: NSObject, NSWindowDelegate {
    private struct Recipe: Equatable {
        let style: BorderShaderStyle
        let configuration: BorderShaderConfiguration?
    }
    private let window: NSWindow
    private let output: AppearanceProfileLog
    private let signposts = OSLog(subsystem: "com.memanager.app", category: "AppearanceAudit")
    private var subscriptions = Set<AnyCancellable>()
    private var host: OverlayGlassHost?
    private weak var instrumentedView: GlassBorderMetalView?
    private var borderOutset: CGFloat = 0
    private var revision = 0
    private var changedAt = CACurrentMediaTime()
    private var targetRenderRevision: Int?
    private var requestedRecipe: Recipe?
    private var awaitsFirstPresentation = false
    private var lastPresentation: TimeInterval?
    private var finished = false

    static var isRequested: Bool {
        TestRuntime.isRunningUnitTests && ProcessInfo.processInfo.arguments.contains("--appearance-audit")
    }

    override init() {
        precondition(Self.isRequested, "Appearance profiling requires isolated runtime storage")
        output = AppearanceProfileLog(arguments: ProcessInfo.processInfo.arguments)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Appearance Audit"
        window.identifier = NSUserInterfaceItemIdentifier("appearance.audit.window")
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 520, height: 500)
        window.delegate = self
        window.center()
        NSApp.setActivationPolicy(.regular)

        let settings = SettingsManager.shared
        let values = Publishers.CombineLatest3(settings.$borderShaderStyle,
            settings.$glassBorderConfiguration, settings.$liquidBorderConfiguration)
        let recipes = values.map { value -> Recipe in
            let (style, glass, liquid) = value
            let configuration: BorderShaderConfiguration?
            switch style {
            case .none: configuration = nil
            case .glass: configuration = glass
            case .liquid: configuration = liquid
            }
            return Recipe(style: style, configuration: configuration)
        }
        let changes = recipes.removeDuplicates()
        changes
            .dropFirst()
            .sink { [weak self] recipe in self?.configurationRequested(recipe) }
            .store(in: &subscriptions)
        window.appearance = settings.overlayAppearance.nativeAppearance
        settings.$overlayAppearance
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] appearance in self?.window.appearance = appearance.nativeAppearance }
            .store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .sink { [weak self] _ in self?.window.appearance = settings.overlayAppearance.nativeAppearance }
            .store(in: &subscriptions)

        // Compile before presenting the controls, as the normal app does while
        // constructing its hidden overlay. The profile UI never blocks on Metal.
        GlassBorderResourcePool.shared.prepare { [weak self] _ in self?.showSurface() }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        instrumentedView?.onFrameCompleted = nil
        instrumentedView?.onFramePresented = nil
        instrumentedView?.onLifecycleEvent = nil
        instrumentedView?.setRenderingEnabled(false)
        host?.onBorderApplied = nil
        subscriptions.removeAll()
        record("sessionEnded")
        output.finish()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    private func showSurface() {
        guard !finished else { return }
        let content = NSHostingView(rootView: AppearanceProfileContent())
        let host = OverlayGlassHost(contentView: content)
        self.host = host
        window.contentView = host
        host.wantsLayer = true
        host.layer?.isOpaque = false
        host.onBorderWidthChange = { [weak self] width in self?.setBorderOutset(width) }
        host.onBorderApplied = { [weak self] style, configuration, renderRevision in
            self?.borderApplied(Recipe(style: style, configuration: configuration), renderRevision: renderRevision)
        }
        setBorderOutset(host.contentInset)
        attachInstrumentation()
        targetRenderRevision = instrumentedView?.configurationRevision
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        record("sessionStarted", extra: ["isolated": true, "processID": ProcessInfo.processInfo.processIdentifier])
    }

    private func setBorderOutset(_ width: CGFloat) {
        let width = width.isFinite ? max(0, width) : 0
        let delta = width - borderOutset
        guard delta != 0 else { return }
        borderOutset = width
        // Expand around the existing content so text keeps its screen position.
        window.setFrame(window.frame.insetBy(dx: -delta, dy: -delta), display: false)
    }

    private func configurationRequested(_ recipe: Recipe) {
        revision += 1
        changedAt = CACurrentMediaTime()
        targetRenderRevision = nil
        requestedRecipe = recipe
        awaitsFirstPresentation = recipe.style != .none
        lastPresentation = nil
        os_signpost(.event, log: signposts, name: "AppearanceRequested", "%{public}@", recipe.style.rawValue)
        record("configurationRequested", mode: recipe.style)
    }

    private func borderApplied(_ recipe: Recipe, renderRevision: Int?) {
        guard !finished, requestedRecipe == recipe else { return }
        requestedRecipe = nil
        attachInstrumentation()
        targetRenderRevision = renderRevision
        awaitsFirstPresentation = renderRevision != nil
        os_signpost(.event, log: signposts, name: "AppearanceApplied")
        record("mainQueueApplied", mode: recipe.style, extra: [
            "applicationSource": "host",
            "applicationLatencyMilliseconds": (CACurrentMediaTime() - changedAt) * 1_000,
            "hasShaderPresentation": renderRevision != nil,
            "appliedRenderRevision": renderRevision ?? -1
        ])
    }

    private func attachInstrumentation() {
        guard let border = host?.subviews.last as? OverlayGlassBorderView,
              let view = border.metalView, instrumentedView !== view else { return }
        instrumentedView = view
        view.onLifecycleEvent = { [weak self] event in
            self?.record("renderLifecycle", extra: [
                "kind": event.kind.rawValue, "lifecycleTimestamp": event.timestamp,
                "generation": event.generation, "renderRevision": event.configurationRevision,
                "canRender": event.canRender, "isAnimating": event.isAnimating,
                "isHiddenOrHasHiddenAncestor": event.isHiddenOrHasHiddenAncestor,
                "hasWindow": event.hasWindow, "windowIsVisible": event.windowIsVisible,
                "windowIsOccluded": event.windowIsOccluded, "displayLinkIsPaused": event.displayLinkIsPaused,
                "drawableWidth": event.drawableSize.width, "drawableHeight": event.drawableSize.height,
                "hasUrgentFramePending": event.hasUrgentFramePending,
                "isFrameInFlight": event.isFrameInFlight
            ])
        }
        view.onFrameCompleted = { [weak self] timing in
            let fields: [String: Any] = [
                "renderRevision": timing.configurationRevision,
                "matchesRequestedConfiguration": timing.configurationRevision == self?.targetRenderRevision,
                "drawableMilliseconds": timing.drawableMilliseconds,
                "encodeMilliseconds": timing.encodeMilliseconds,
                "gpuMilliseconds": timing.gpuMilliseconds,
                "drawableWidth": timing.drawableSize.width,
                "drawableHeight": timing.drawableSize.height,
                "sampledAt": timing.sampledAt,
                "gpuEndTime": timing.gpuEndTime,
                "submittedAt": timing.submittedAt,
                "predictedPresentationTime": timing.predictedPresentationTime
            ]
            self?.record("frameCompleted", extra: fields)
        }
        view.onFramePresented = { [weak self] timing in
            guard let self else { return }
            let time = timing.presentedTime
            let matches = timing.isCurrentGeneration
                && timing.configurationRevision == self.targetRenderRevision && time >= self.changedAt
            var fields: [String: Any] = ["presentedTime": time, "sampledAt": timing.sampledAt,
                "renderRevision": timing.configurationRevision, "matchesRequestedConfiguration": matches,
                "isCurrentGeneration": timing.isCurrentGeneration,
                "predictedPresentationTime": timing.predictedPresentationTime]
            if time > 0 {
                fields["presentationPredictionErrorMilliseconds"] = (time - timing.predictedPresentationTime) * 1_000
            }
            guard time > 0 else { self.record("drawableNotPresented", extra: fields); return }
            if matches, let previous = self.lastPresentation, time >= previous {
                fields["presentationIntervalMilliseconds"] = (time - previous) * 1_000
            }
            if matches { self.lastPresentation = time }
            if matches && self.awaitsFirstPresentation {
                self.awaitsFirstPresentation = false
                fields["requestToPresentationMilliseconds"] = (time - self.changedAt) * 1_000
                os_signpost(.event, log: self.signposts, name: "AppearancePresented")
            }
            self.record("framePresented", extra: fields)
        }
    }

    private func record(_ event: String, mode: BorderShaderStyle? = nil, extra: [String: Any] = [:]) {
        guard !finished || event == "sessionEnded" else { return }
        let now = CACurrentMediaTime()
        var fields: [String: Any] = [
            "event": event, "timestamp": now, "revision": revision,
            "mode": (mode ?? SettingsManager.shared.borderShaderStyle).rawValue,
            "millisecondsSinceChange": (now - changedAt) * 1_000,
            // Settled samples exclude the transition from steady frame statistics;
            // render revisions independently reject callbacks from the old recipe.
            "settled": now - changedAt >= 0.1,
            "contentWidth": host?.hostedContent.bounds.width ?? 0,
            "contentHeight": host?.hostedContent.bounds.height ?? 0
        ]
        fields.merge(extra) { _, new in new }
        output.append(fields)
    }
}

private struct AppearanceProfileContent: View {
    @ObservedObject private var settings = SettingsManager.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    Text("Appearance audit | Isolated settings")
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textSecondary)
                    AppearanceSettingsView()
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .environment(\.settingsBreakpoint, OverlayLayout.breakpoint(for: geometry.size.width))
        }
        .background(OverlayPalette.canvas.opacity(backgroundOpacity))
        .tint(OverlayPalette.accent)
        .preferredColorScheme(settings.overlayAppearance.colorScheme)
    }

    private var backgroundOpacity: Double {
        if reduceTransparency || contrast == .increased { return 1 }
        guard settings.borderShaderStyle == .none else { return 0.82 }
        return settings.overlayOpacity.isFinite ? min(1, max(0.5, settings.overlayOpacity)) : 0.95
    }
}
