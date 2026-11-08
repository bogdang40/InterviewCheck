import AppKit
import Combine

/// Stable content sits above the optional material, so removing the border
/// never reparents an editor or hides it with the native glass background.
final class OverlayGlassHost: NSView {
    enum TintPlacement { case native, overlay }
    enum MaterialBehavior { case adaptiveGlass, stableReading }

    let hostedContent: NSView
    let contentContainer: NSView
    private(set) var contentInset: CGFloat
    var onBorderWidthChange: ((CGFloat) -> Void)?
    /// Optional diagnostics, delivered after native geometry and the renderer
    /// accept a recipe. A nil revision means no shader presentation is expected.
    var onBorderApplied: ((BorderShaderStyle, BorderShaderConfiguration?, Int?) -> Void)?
    private let innerContentView: NSView
    private let materialView: NSView
    private let borderView: OverlayGlassBorderView
    private let requestedContentCornerRadius: CGFloat
    private let materialTint: NSColor?
    private let tintPlacement: TintPlacement
    private let materialBehavior: MaterialBehavior
    private(set) var materialOverlay: NSBox?
    private var insetConstraints: [NSLayoutConstraint] = []
    private var borderStyle: BorderShaderStyle
    private var borderConfiguration: BorderShaderConfiguration?
    private var isResizingBorder = false
    private var opacitySubscription: AnyCancellable?
    private var borderSubscription: AnyCancellable?
    private let opacityDelivery = AppearanceUpdateDelivery()
    private let borderDelivery = AppearanceUpdateDelivery()
    private var legacyTintView: NSBox?

    init(contentView: NSView, cornerRadius: CGFloat = 26, materialTint: NSColor? = nil,
         tintPlacement: TintPlacement = .native, observesSettings: Bool = true,
         materialBehavior: MaterialBehavior = .adaptiveGlass) {
        let settings = SettingsManager.shared
        let style = settings.borderShaderStyle
        let configuration = settings.configuration(for: style)
        let radius = cornerRadius.isFinite ? max(0, cornerRadius) : 0
        requestedContentCornerRadius = radius
        self.materialTint = materialTint
        self.tintPlacement = tintPlacement
        self.materialBehavior = materialBehavior
        borderStyle = style
        borderConfiguration = configuration
        contentInset = configuration.map { CGFloat($0.width) } ?? 0
        let outerRadius = radius + contentInset
        hostedContent = contentView
        let container = NSView()
        contentContainer = container
        let inner = NSView()
        innerContentView = inner
        inner.wantsLayer = true
        inner.layer?.cornerRadius = radius
        inner.layer?.masksToBounds = true
        inner.addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(inner)
        inner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: inner.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: inner.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: inner.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: inner.bottomAnchor)
        ])
        insetConstraints = [
            inner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: contentInset),
            inner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -contentInset),
            inner.topAnchor.constraint(equalTo: container.topAnchor, constant: contentInset),
            inner.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -contentInset)
        ]
        NSLayoutConstraint.activate(insetConstraints)
        if #available(macOS 26.0, *), materialBehavior == .adaptiveGlass {
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.cornerRadius = outerRadius
            materialView = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .underWindowBackground
            material.blendingMode = .behindWindow
            // A reading surface must keep its blur while the window gains or
            // loses focus. Native glass has no public activity override.
            material.state = .active
            material.isEmphasized = false
            material.maskImage = Self.roundedMask(radius: outerRadius)
            let tint = NSBox()
            tint.boxType = .custom
            tint.borderType = .noBorder
            tint.cornerRadius = outerRadius
            material.addSubview(tint)
            tint.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                tint.leadingAnchor.constraint(equalTo: material.leadingAnchor),
                tint.trailingAnchor.constraint(equalTo: material.trailingAnchor),
                tint.topAnchor.constraint(equalTo: material.topAnchor),
                tint.bottomAnchor.constraint(equalTo: material.bottomAnchor)
            ])
            legacyTintView = tint
            materialView = material
        }
        borderView = OverlayGlassBorderView(cornerRadius: outerRadius, inset: contentInset,
            style: style, configuration: configuration)
        super.init(frame: .zero)
        clipsToBounds = false
        // Floating surfaces use literal alpha above untinted native glass.
        // NSGlassEffectView.tintColor is a material color target, not opacity.
        if tintPlacement == .overlay {
            let tint = NSBox()
            tint.boxType = .custom
            tint.borderType = .noBorder
            tint.cornerRadius = outerRadius
            tint.fillColor = .clear
            materialOverlay = tint
        }
        // The legacy host retains its three stable siblings and ordering.
        let layers = [materialView] + (materialOverlay.map { [$0] } ?? []) + [container, borderView]
        for view in layers {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
        materialView.isHidden = style == .none
        materialOverlay?.isHidden = style == .none
        updateMaterialOpacity(settings.overlayOpacity)
        guard observesSettings else { return }
        opacitySubscription = settings.$overlayOpacity
            .removeDuplicates()
            .dropFirst() // The initial tint was applied above.
            .sink { [weak self] opacity in
                self?.opacityDelivery.submit { [weak self] in
                    self?.updateMaterialOpacity(opacity)
                }
            }
        borderSubscription = Publishers.CombineLatest3(settings.$borderShaderStyle,
            settings.$glassBorderConfiguration, settings.$liquidBorderConfiguration)
            .dropFirst() // The initial recipe was applied above before mounting.
            .sink { [weak self] style, glass, liquid in
                let configuration = style == .none ? nil : (style == .glass ? glass : liquid)
                // Defer native layout until @Published has stored this recipe;
                // resizing during willSet can render SwiftUI against the old selection.
                self?.borderDelivery.submit { [weak self] in
                    self?.updateBorder(style: style, configuration: configuration)
                }
            }
    }

    override func layout() {
        updateBorderGeometry()
        super.layout()
    }

    /// External owners apply one committed recipe to all floating islands.
    /// The default host still observes settings for legacy callers.
    func applyAppearance(style: BorderShaderStyle, configuration: BorderShaderConfiguration?,
                         opacity: Double, usesSolidFallback: Bool) {
        updateBorder(style: style, configuration: configuration)
        updateMaterialOpacity(opacity)
        materialView.isHidden = style == .none || usesSolidFallback
        materialOverlay?.isHidden = materialView.isHidden
    }

    func updateBorder(style: BorderShaderStyle, configuration: BorderShaderConfiguration?) {
        let configuration = style == .none ? nil
            : (configuration ?? .preset(for: style))?.sanitized(
                fallback: BorderShaderConfiguration.preset(for: style) ?? .glassDefault)
        defer {
            let revision = style == .none || borderView.usesSolidBorder
                ? nil : borderView.metalView?.configurationRevision
            onBorderApplied?(style, configuration, revision)
        }
        guard borderStyle != style || borderConfiguration != configuration else { return }
        let previousWidth = borderConfiguration?.width ?? 0
        borderStyle = style
        borderConfiguration = configuration
        let width = configuration?.width ?? 0
        if previousWidth != width {
            // Keep frame production paused while a native resize can lay out
            // this host recursively. None also removes the rim before shrinking.
            isResizingBorder = true
            borderView.metalView?.setRenderingEnabled(false)
            if style == .none {
                materialView.isHidden = true
                materialOverlay?.isHidden = true
                borderView.isHidden = true
            }
            // Install the new inset first so synchronous window layout never
            // observes the old content viewport. Reveal only at the final size.
            updateBorderGeometry()
            onBorderWidthChange?(CGFloat(width))
            layoutSubtreeIfNeeded()
            isResizingBorder = false
        }
        materialView.isHidden = style == .none
        materialOverlay?.isHidden = style == .none
        updateBorderGeometry()
    }

    private func updateBorderGeometry() {
        let halfMinimum = min(bounds.width, bounds.height) / 2
        let hasSize = halfMinimum.isFinite && halfMinimum > 0
        let requestedInset = borderConfiguration.map { CGFloat($0.width) } ?? 0
        let inset = hasSize ? min(requestedInset, halfMinimum) : requestedInset
        let contentRadius = hasSize ? min(requestedContentCornerRadius, max(0, halfMinimum - inset))
            : requestedContentCornerRadius
        let radius = contentRadius + inset
        if contentInset != inset {
            contentInset = inset
            for (index, constraint) in insetConstraints.enumerated() {
                constraint.constant = index.isMultiple(of: 2) ? inset : -inset
            }
        }
        if innerContentView.layer?.cornerRadius != contentRadius {
            innerContentView.layer?.cornerRadius = contentRadius
        }
        guard !isResizingBorder else { return }
        materialOverlay?.cornerRadius = radius
        if borderView.cornerRadius != radius {
            if #available(macOS 26.0, *), let glass = materialView as? NSGlassEffectView {
                glass.cornerRadius = radius
            } else if let material = materialView as? NSVisualEffectView {
                material.maskImage = Self.roundedMask(radius: radius)
                legacyTintView?.cornerRadius = radius
            }
        }
        borderView.configure(style: borderStyle, configuration: borderConfiguration,
                             cornerRadius: radius, inset: inset)
    }

    /// Changes only the material tint; selection and content remain untouched.
    func updateMaterialOpacity(_ opacity: Double) {
        let opacity = opacity.isFinite ? opacity : 0.95
        let fraction = CGFloat(min(1, max(0, (opacity - 0.5) / 0.5)))
        let amount = materialBehavior == .stableReading ? 0.24 + fraction * 0.12
            : (materialTint == nil ? fraction * 0.2 : 0.12 + fraction * 0.08)
        let tint = (materialTint ?? NSColor.windowBackgroundColor).withAlphaComponent(amount)
        if #available(macOS 26.0, *), let glass = materialView as? NSGlassEffectView {
            if tintPlacement == .overlay {
                if glass.tintColor != nil { glass.tintColor = nil }
            } else {
                glass.tintColor = tint
            }
        } else {
            legacyTintView?.fillColor = tintPlacement == .overlay ? .clear : tint
        }
        if materialOverlay?.fillColor != tint { materialOverlay?.fillColor = tint }
    }

    required init?(coder: NSCoder) { nil }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let size = NSSize(width: radius * 2 + 1, height: radius * 2 + 1)
        let mask = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        return mask
    }
}
