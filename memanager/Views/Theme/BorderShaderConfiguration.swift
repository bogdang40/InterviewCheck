import Foundation

/// A saved material recipe. Values use points and the units shown in Appearance.
struct BorderShaderConfiguration: Codable, Equatable {
    static let defaultWidth: Double = 6

    var width: Double = Self.defaultWidth
    var depth: Double = 6
    var ior: Double = 1.65
    var dispersion: Double = 0.035
    var roughness: Double = 0.004
    var fluidity: Double = 0.65
    var waterRipples: Double = 0
    var reflectionStrength: Double = 1
    var transmissionShare: Double = 0.08
    var lightStrength: Double = 1
    var animationEnabled = true
    var motionSpeed: Double = 1

    static let glassDefault: Self = {
        let configuration = Self()
        return configuration.sanitized(fallback: configuration)
    }()
    static let liquidDefault: Self = {
        let configuration = Self(ior: 1.333, dispersion: 0.006,
            roughness: 0.012, fluidity: 0.85, waterRipples: 1, transmissionShare: 0.1, lightStrength: 0.8)
        return configuration.sanitized(fallback: configuration)
    }()

    static func preset(for style: BorderShaderStyle) -> Self? {
        switch style {
        case .glass: return .glassDefault
        case .liquid: return .liquidDefault
        case .none: return nil
        }
    }

    /// Conservative curvature bound for the contour and water waves at the highest RGB IOR.
    var maximumDepth: Double {
        let radius = Self.bounded(width, to: 2...48, fallback: Self.defaultWidth) / 2
        let highestIOR = max(1.0001, Self.bounded(ior, to: 1...2.2, fallback: 1.65)
            + Self.bounded(dispersion, to: 0...0.06, fallback: 0.035))
        let amplitude = 0.24 * radius * Self.bounded(fluidity, to: 0...1, fallback: 0.65)
        let contourSlope = 1 + amplitude * 0.0239
        let contourCurvature = amplitude * 0.000585
        let water = Self.bounded(waterRipples, to: 0...1, fallback: 0)
        let profile = 1 - 0.04 * water
        let rippleSlope = 0.18 * water * 0.1019
        let rippleCurvature = 0.18 * water * 0.01082
        let curvature = profile * rippleCurvature
            + profile * profile / (radius * radius) * (contourSlope * contourSlope + radius * contourCurvature)
            + 4 * profile / radius * rippleSlope * contourSlope
        return min(30, sqrt(0.70 / ((1 - 1 / highestIOR) * curvature)))
    }

    var effectiveDepth: Double {
        min(Self.bounded(depth, to: 1...30, fallback: 6), maximumDepth)
    }

    /// Clamp file and programmatic input before publishing it or sending it to Metal.
    func sanitized(fallback: Self = .glassDefault) -> Self {
        var result = self
        result.width = Self.bounded(width, to: 2...48, fallback: fallback.width)
        result.ior = Self.bounded(ior, to: 1...2.2, fallback: fallback.ior)
        result.dispersion = Self.bounded(dispersion, to: 0...0.06, fallback: fallback.dispersion)
        result.roughness = Self.bounded(roughness, to: 0...0.08, fallback: fallback.roughness)
        result.fluidity = Self.bounded(fluidity, to: 0...1, fallback: fallback.fluidity)
        result.waterRipples = Self.bounded(waterRipples, to: 0...1, fallback: fallback.waterRipples)
        result.depth = min(Self.bounded(depth, to: 1...30, fallback: fallback.depth), result.maximumDepth)
        result.reflectionStrength = Self.bounded(reflectionStrength, to: 0...1, fallback: fallback.reflectionStrength)
        result.transmissionShare = Self.bounded(transmissionShare, to: 0...0.35, fallback: fallback.transmissionShare)
        result.lightStrength = Self.bounded(lightStrength, to: 0...1, fallback: fallback.lightStrength)
        result.motionSpeed = Self.bounded(motionSpeed, to: 0.1...2, fallback: fallback.motionSpeed)
        return result
    }

    var optics: GlassBorderOptics {
        let valid = sanitized()
        return GlassBorderOptics(ior: Float(valid.ior), thickness: Float(valid.depth * 2),
            roughness: Float(valid.roughness), reflectionStrength: Float(valid.reflectionStrength),
            dispersion: Float(valid.dispersion), transmissionEnvironmentShare: Float(valid.transmissionShare),
            gooey: Float(valid.fluidity), lightMotion: Float(valid.lightStrength), liquid: Float(valid.waterRipples))
    }

    private static func bounded(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, value.isFinite ? value : fallback))
    }
}

/// UserDefaults is injected so persistence can be checked without changing app preferences.
struct BorderShaderConfigurationStore {
    let defaults: UserDefaults

    func load(for style: BorderShaderStyle) -> BorderShaderConfiguration? {
        guard let fallback = BorderShaderConfiguration.preset(for: style) else { return nil }
        guard let data = defaults.data(forKey: key(for: style)) else { return fallback }
        do {
            return try JSONDecoder().decode(BorderShaderConfiguration.self, from: data).sanitized(fallback: fallback)
        } catch {
            NSLog("[BorderShaderConfiguration] Failed to restore %@: %@", style.rawValue, error.localizedDescription)
            return fallback
        }
    }

    @discardableResult
    func save(_ configuration: BorderShaderConfiguration, for style: BorderShaderStyle) throws -> BorderShaderConfiguration? {
        guard let fallback = BorderShaderConfiguration.preset(for: style) else { return nil }
        let valid = configuration.sanitized(fallback: fallback)
        defaults.set(try JSONEncoder().encode(valid), forKey: key(for: style))
        return valid
    }

    private func key(for style: BorderShaderStyle) -> String {
        "memanager.borderShader.\(style.rawValue)Configuration"
    }
}
