import AppKit

/// Owns the selected optical rim while the native material stays mounted.
/// None pauses the retained renderer and paints nothing.
final class OverlayGlassBorderView: NSView {
    private(set) var cornerRadius: CGFloat
    private(set) var inset: CGFloat
    private(set) var metalView: GlassBorderMetalView?
    private(set) var style: BorderShaderStyle
    private(set) var usesSolidBorder = false
    private var configuration: BorderShaderConfiguration?
    private var accessibilityObserver: NSObjectProtocol?
    private var resources: GlassBorderResources?
    private var preparationFailed = false

    init(cornerRadius: CGFloat, inset: CGFloat, style: BorderShaderStyle = .glass,
         configuration: BorderShaderConfiguration? = nil,
         resourcePool: GlassBorderResourcePool? = nil) {
        self.cornerRadius = cornerRadius
        self.inset = inset
        self.style = style
        self.configuration = (configuration ?? BorderShaderConfiguration.preset(for: style))?.sanitized(
            fallback: BorderShaderConfiguration.preset(for: style) ?? .glassDefault)
        super.init(frame: .zero)
        let resourcePool = resourcePool ?? .shared
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.updatePresentation() }
        updatePresentation()
        resourcePool.prepare { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let resources): self.resources = resources
            case .failure: self.preparationFailed = true
            }
            self.updatePresentation()
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override var isOpaque: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        metalView?.requestFrame()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        metalView?.requestFrame()
    }

    func setStyle(_ style: BorderShaderStyle) {
        configure(style: style, configuration: .preset(for: style), cornerRadius: cornerRadius, inset: inset)
    }

    func configure(style: BorderShaderStyle, configuration: BorderShaderConfiguration?,
                   cornerRadius: CGFloat, inset: CGFloat) {
        let valid = style == .none ? nil : configuration?.sanitized(
            fallback: BorderShaderConfiguration.preset(for: style) ?? .glassDefault)
        guard self.style != style || self.configuration != valid
            || self.cornerRadius != cornerRadius || self.inset != inset else { return }
        self.style = style
        self.configuration = valid
        self.cornerRadius = cornerRadius
        self.inset = inset
        updatePresentation()
    }

    private func updatePresentation() {
        isHidden = style == .none
        guard style != .none, let configuration else {
            usesSolidBorder = false
            metalView?.setRenderingEnabled(false)
            metalView?.isHidden = true
            needsDisplay = true
            return
        }
        let workspace = NSWorkspace.shared
        let requiresSolidBorder = workspace.accessibilityDisplayShouldReduceTransparency
            || workspace.accessibilityDisplayShouldIncreaseContrast
        if !requiresSolidBorder && metalView == nil {
            installMetalView(configuration: configuration)
        }
        usesSolidBorder = requiresSolidBorder || preparationFailed || metalView?.hasFailed == true
        metalView?.setRenderingEnabled(!usesSolidBorder)
        metalView?.configure(cornerRadius: cornerRadius, inset: inset, optics: configuration.optics,
            animationEnabled: configuration.animationEnabled, motionSpeed: configuration.motionSpeed)
        metalView?.isHidden = usesSolidBorder
        if !usesSolidBorder { metalView?.requestFrame() }
        needsDisplay = true
    }

    private func installMetalView(configuration: BorderShaderConfiguration) {
        guard let resources else { return }
        let view = GlassBorderMetalView(cornerRadius: cornerRadius, inset: inset, resources: resources,
            optics: configuration.optics, animationEnabled: configuration.animationEnabled,
            motionSpeed: configuration.motionSpeed)
        metalView = view
        view.onFailure = { [weak self] in self?.updatePresentation() }
        addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        guard usesSolidBorder, let context = NSGraphicsContext.current?.cgContext else { return }
        let outer = CGPath(roundedRect: bounds, cornerWidth: cornerRadius,
                           cornerHeight: cornerRadius, transform: nil)
        let inner = CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                           cornerWidth: max(0, cornerRadius - inset),
                           cornerHeight: max(0, cornerRadius - inset), transform: nil)
        context.saveGState()
        context.addPath(outer)
        context.addPath(inner)
        context.clip(using: .evenOdd)
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(bounds)
        context.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.65).cgColor)
        context.setLineWidth(1)
        context.addPath(outer)
        context.addPath(inner)
        context.strokePath()
        context.restoreGState()
    }
}
