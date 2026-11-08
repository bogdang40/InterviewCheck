import AppKit
import SwiftUI

/// One committed SwiftUI snapshot controls geometry, native glass and the
/// reading fallback. Floating hosts have no independent settings observers.
struct FloatingGlassAppearance: Equatable {
    let style: BorderShaderStyle
    let configuration: BorderShaderConfiguration?
    let opacity: Double
    let usesSolidFallback: Bool
    let colorScheme: ColorScheme

    static var current: Self {
        let settings = SettingsManager.shared
        return Self(style: settings.borderShaderStyle,
            configuration: settings.configuration(for: settings.borderShaderStyle),
            opacity: settings.overlayOpacity,
            usesSolidFallback: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            colorScheme: settings.overlayAppearance.colorScheme
                ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light))
    }
}

struct FloatingGlassBackdrop: NSViewRepresentable {
    let geometry: FloatingShellGeometry
    private let committedAppearance: FloatingGlassAppearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    init(geometry: FloatingShellGeometry, appearance: FloatingGlassAppearance = .current) {
        self.geometry = geometry
        committedAppearance = appearance
    }

    private var appearance: FloatingGlassAppearance {
        FloatingGlassAppearance(style: committedAppearance.style,
            configuration: committedAppearance.configuration,
            opacity: committedAppearance.opacity, usesSolidFallback: reduceTransparency || contrast == .increased,
            colorScheme: colorScheme)
    }

    func makeNSView(context: Context) -> FloatingGlassBackdropView {
        FloatingGlassBackdropView(geometry: geometry, appearance: appearance)
    }

    func updateNSView(_ view: FloatingGlassBackdropView, context: Context) {
        view.update(geometry: geometry, appearance: appearance)
    }

    static func dismantleNSView(_ view: FloatingGlassBackdropView, coordinator: ()) {
        view.detachPointerRegions()
    }
}

final class FloatingGlassBackdropView: NSView {
    private var geometry: FloatingShellGeometry
    private var recipe: FloatingGlassAppearance
    private weak var regionWindow: OverlayWindow?
    private let cornerRadii: [CGFloat] = [26, 26, 24]
    private let hosts: [OverlayGlassHost]
    private let readingViews: [NSHostingView<OverlayReadingSurface>]

    init(geometry: FloatingShellGeometry, appearance: FloatingGlassAppearance = .current) {
        self.geometry = geometry
        recipe = appearance
        let forest = NSColor(srgbRed: 32.0 / 255, green: 58.0 / 255, blue: 44.0 / 255, alpha: 1)
        let readingSurfaces = [26, 26, 24].map { radius in
            let view = NSHostingView(rootView: OverlayReadingSurface(style: appearance.style, opacity: appearance.opacity,
                usesSolidFallback: appearance.usesSolidFallback, cornerRadius: CGFloat(radius)))
            view.sizingOptions = []
            view.wantsLayer = true
            view.layer?.isOpaque = false
            view.layer?.backgroundColor = CGColor.clear
            return view
        }
        readingViews = readingSurfaces
        hosts = zip(readingSurfaces, [26, 26, 24]).map { view, radius in
            OverlayGlassHost(contentView: view, cornerRadius: CGFloat(radius), materialTint: forest,
                tintPlacement: .overlay, observesSettings: false, materialBehavior: .stableReading)
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CGColor.clear
        layer?.isOpaque = false
        hosts.forEach { addSubview($0) }
        update(geometry: geometry, appearance: appearance)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    func update(geometry: FloatingShellGeometry, appearance: FloatingGlassAppearance? = nil) {
        let next = appearance ?? recipe
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        regionWindow?.applyFloatingBorderOutset(geometry.borderWidth, from: self)
        // A border change may synchronously resize the root viewport. Use its
        // final native size before any material becomes visible.
        self.geometry = regionWindow.map {
            FloatingShellGeometry(size: $0.contentLayoutRect.size, borderWidth: geometry.borderWidth)
        } ?? geometry
        let appearanceName: NSAppearance.Name = next.colorScheme == .dark ? .darkAqua : .aqua
        if self.appearance?.name != appearanceName { self.appearance = NSAppearance(named: appearanceName) }
        let rects = [self.geometry.navigation, self.geometry.content, self.geometry.dock]
        for (index, host) in hosts.enumerated() {
            let reading = readingViews[index]
            if next.style != recipe.style || next.opacity != recipe.opacity
                || next.usesSolidFallback != recipe.usesSolidFallback {
                reading.rootView = OverlayReadingSurface(style: next.style, opacity: next.opacity,
                    usesSolidFallback: next.usesSolidFallback, cornerRadius: cornerRadii[index])
            }
            let outer = rects[index].insetBy(dx: -geometry.borderWidth, dy: -geometry.borderWidth)
            if host.frame != outer { host.frame = outer }
            host.applyAppearance(style: next.style, configuration: next.configuration,
                opacity: next.opacity, usesSolidFallback: next.usesSolidFallback)
            host.layoutSubtreeIfNeeded()
            reading.layoutSubtreeIfNeeded()
        }
        recipe = next
        updatePointerRegions()
    }

    override func layout() {
        super.layout()
        updatePointerRegions()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if regionWindow !== window { detachPointerRegions() }
        regionWindow = window as? OverlayWindow
        update(geometry: geometry)
    }

    func detachPointerRegions() {
        regionWindow?.removeFloatingGlassHitRegions(in: self)
        regionWindow?.releaseFloatingBorderOutset(from: self)
        regionWindow = nil
    }

    private func updatePointerRegions() {
        let regions = zip(hosts, cornerRadii).map { host, radius in
            OverlayGlassHitRegion(rect: host.frame, cornerRadius: radius + geometry.borderWidth)
        }
        regionWindow?.updateFloatingGlassHitRegions(regions, in: self)
    }
}
