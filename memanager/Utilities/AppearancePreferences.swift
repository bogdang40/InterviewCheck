import Foundation

/// Validates persisted values before they reach layout or integer formatting.
struct AppearancePreferences {
    let opacity: Double
    let fontSize: Double
    let width: CGFloat

    init(defaults: UserDefaults) {
        opacity = Self.restore(defaults.double(forKey: "memanager.overlayOpacity"),
                               fallback: 0.95, range: 0.5...1)
        fontSize = Self.restore(defaults.double(forKey: "memanager.fontSize"),
                                fallback: 14, range: 10...24)
        let storedWidth = defaults.double(forKey: "memanager.overlayWidth")
        width = storedWidth.isFinite && storedWidth > 0 ? max(400, storedWidth) : 800
    }

    private static func restore(_ value: Double, fallback: Double,
                                range: ClosedRange<Double>) -> Double {
        guard value.isFinite, value > 0 else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}
