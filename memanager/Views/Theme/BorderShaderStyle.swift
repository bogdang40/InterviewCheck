/// The optional custom material above the native panel backdrop.
enum BorderShaderStyle: String, CaseIterable, Identifiable {
    case glass
    case liquid
    case none

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var description: String {
        switch self {
        case .glass: return "A clear crystal edge with moving reflections."
        case .liquid: return "Water with flowing ripples and soft reflections."
        case .none: return "A softly textured reading surface."
        }
    }

    var optics: GlassBorderOptics? {
        switch self {
        case .glass: return GlassBorderOptics()
        case .liquid:
            return GlassBorderOptics(ior: 1.333, thickness: 12, roughness: 0.012,
                dispersion: 0.006, transmissionEnvironmentShare: 0.1,
                gooey: 0.85, lightMotion: 0.8, liquid: 1)
        case .none: return nil
        }
    }

    static func restored(from value: String?) -> BorderShaderStyle {
        value.flatMap(Self.init(rawValue:)) ?? .liquid
    }
}
