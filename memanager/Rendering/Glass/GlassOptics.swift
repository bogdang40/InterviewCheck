import CoreGraphics
import Foundation
import simd

struct GlassBorderOptics {
    var ior: Float
    var thickness: Float
    var roughness: Float
    var reflectionStrength: Float
    var dispersion: Float
    var transmissionEnvironmentShare: Float
    var gooey: Float
    var lightMotion: Float
    var liquid: Float

    init(ior: Float = 1.65, thickness: Float = 12, roughness: Float = 0.004,
         reflectionStrength: Float = 1, dispersion: Float = 0.035,
         transmissionEnvironmentShare: Float = 0.08, gooey: Float = 0.65, lightMotion: Float = 1,
         liquid: Float = 0) {
        self.ior = ior
        self.thickness = thickness
        self.roughness = roughness
        self.reflectionStrength = reflectionStrength
        self.dispersion = dispersion
        self.transmissionEnvironmentShare = transmissionEnvironmentShare
        self.gooey = gooey
        self.lightMotion = lightMotion
        self.liquid = liquid
    }
}

struct GlassBorderUniforms {
    var shape: SIMD4<Float>
    var optics: SIMD4<Float>
    var output = SIMD4<Float>(1, 0, 0, 0)
    var transmission: SIMD4<Float>
    var animation: SIMD4<Float>

    init(viewSize: CGSize, cornerRadius: CGFloat, shoulderWidth: CGFloat,
         optics: GlassBorderOptics, time: Float = 0) throws {
        guard [viewSize.width, viewSize.height].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 100_000 }),
              cornerRadius.isFinite, cornerRadius >= 0,
              shoulderWidth.isFinite, shoulderWidth > 0 else { throw GlassRenderError.invalidGeometry }
        guard optics.ior.isFinite, (1...3).contains(optics.ior),
              optics.thickness.isFinite, (0...100).contains(optics.thickness),
              optics.roughness.isFinite, (0...0.1).contains(optics.roughness),
              optics.reflectionStrength.isFinite, (0...1).contains(optics.reflectionStrength),
              optics.dispersion.isFinite, (0...0.1).contains(optics.dispersion),
              optics.transmissionEnvironmentShare.isFinite,
              (0...0.35).contains(optics.transmissionEnvironmentShare),
              optics.gooey.isFinite, (0...1).contains(optics.gooey),
              optics.lightMotion.isFinite, (0...1).contains(optics.lightMotion),
              optics.liquid.isFinite, (0...1).contains(optics.liquid),
              time.isFinite, time >= 0 else {
            throw GlassRenderError.invalidOptics
        }
        let halfMinimum = min(viewSize.width, viewSize.height) / 2
        shape = SIMD4(Float(viewSize.width), Float(viewSize.height),
                      Float(min(cornerRadius, halfMinimum)), Float(min(shoulderWidth, halfMinimum)))
        self.optics = SIMD4(optics.ior, optics.thickness, optics.roughness, optics.reflectionStrength)
        transmission = SIMD4(optics.dispersion, optics.transmissionEnvironmentShare, 0, 0)
        animation = SIMD4(time, optics.gooey, optics.lightMotion, optics.liquid)
    }
}

enum GlassRenderError: Error, LocalizedError {
    case missingKernel
    case encoderUnavailable
    case invalidGeometry
    case invalidOptics
    case invalidTextures

    var errorDescription: String? {
        switch self {
        case .missingKernel: return "The glass optics Metal kernel is unavailable."
        case .encoderUnavailable: return "Metal could not create a glass rendering encoder."
        case .invalidGeometry: return "Glass rendering received invalid scene geometry."
        case .invalidOptics: return "Glass rendering received invalid optical parameters."
        case .invalidTextures: return "Glass rendering received an incompatible Metal texture or command buffer."
        }
    }
}
