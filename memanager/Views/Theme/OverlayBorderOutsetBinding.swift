import AppKit
import Combine

/// Legacy roots follow settings. A floating root owns its window outset and
/// pane recipe together, so no deferred observer can resize them independently.
final class OverlayBorderOutsetBinding {
    private weak var owner: NSView?
    private var subscription: AnyCancellable?
    private var delivery = AppearanceUpdateDelivery()

    func bind(contentView: NSView, apply: @escaping (CGFloat) -> Void) {
        guard owner == nil else { return }
        subscription = nil
        delivery = AppearanceUpdateDelivery()
        if let host = contentView as? OverlayGlassHost {
            host.onBorderWidthChange = apply
            apply(host.contentInset)
        } else {
            let settings = SettingsManager.shared
            subscription = Publishers.CombineLatest3(settings.$borderShaderStyle,
                settings.$glassBorderConfiguration, settings.$liquidBorderConfiguration)
                .sink { [weak self] style, glass, liquid in
                    self?.delivery.submit {
                        apply(CGFloat(style == .none ? 0 : (style == .glass ? glass.width : liquid.width)))
                    }
                }
        }
    }

    func takeOwnership(_ view: NSView) {
        guard owner !== view else { return }
        owner = view
        subscription = nil
        // Invalidates the weakly scheduled delivery from the previous owner.
        delivery = AppearanceUpdateDelivery()
    }

    func releaseOwnership(_ view: NSView) -> Bool {
        guard owner === view else { return false }
        owner = nil
        return true
    }
}
