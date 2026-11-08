import Foundation
import Metal

/// Encodes crystal volume optics against a virtual studio. No desktop capture path.
final class GlassOpticsRenderer {
    let device: MTLDevice
    private let borderPipeline: MTLComputePipelineState

    init(device: MTLDevice, library: MTLLibrary? = nil) throws {
        self.device = device
        let library = try library ?? device.makeDefaultLibrary(bundle: Bundle(for: GlassOpticsRenderer.self))
        guard let border = library.makeFunction(name: "glassBorder") else { throw GlassRenderError.missingKernel }
        borderPipeline = try device.makeComputePipelineState(function: border)
    }

    /// A transparent reflection and dispersed transmission layer. Native glass supplies the backdrop.
    func encodeBorder(destination: MTLTexture, commandBuffer: MTLCommandBuffer,
                      viewSize: CGSize, cornerRadius: CGFloat = 36, shoulderWidth: CGFloat = 12,
                      optics: GlassBorderOptics = GlassBorderOptics(), time: Float = 0) throws {
        guard destination.device.registryID == device.registryID,
              commandBuffer.device.registryID == device.registryID,
              destination.textureType == .type2D, !destination.isFramebufferOnly else {
            throw GlassRenderError.invalidTextures
        }
        var uniforms = try GlassBorderUniforms(viewSize: viewSize, cornerRadius: cornerRadius,
                                              shoulderWidth: shoulderWidth, optics: optics, time: time)
        switch destination.pixelFormat {
        case .bgra8Unorm, .rgba8Unorm: uniforms.output.x = 1
        case .rgba16Float, .rgba32Float: uniforms.output.x = 0
        default: throw GlassRenderError.invalidTextures
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw GlassRenderError.encoderUnavailable
        }
        encoder.label = "Crystal glass volume optics"
        encoder.setComputePipelineState(borderPipeline)
        encoder.setTexture(destination, index: 0)
        encoder.setBytes(&uniforms, length: MemoryLayout<GlassBorderUniforms>.stride, index: 0)
        // Narrow groups avoid running inactive lanes beside the vertical rim.
        // Full-resolution benchmarks favor 4x32 over 16x8 on Apple GPUs.
        let isAppleGPU = device.supportsFamily(.apple1)
        let width = min(isAppleGPU ? 4 : 16, borderPipeline.threadExecutionWidth)
        let height = min(isAppleGPU ? 32 : 8, borderPipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(MTLSize(width: destination.width, height: destination.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        encoder.endEncoding()
    }

}
