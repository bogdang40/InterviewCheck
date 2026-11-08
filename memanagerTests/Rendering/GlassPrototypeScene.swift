import AppKit
import Metal
import XCTest
@testable import memanager

/// Owned, deterministic pixels. These fixtures never sample the desktop.
enum GlassPrototypeScene: String {
    case grid, stone

    func pixels(width: Int, height: Int, phase: Double = 0) -> GlassPrototypePixels {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let px = Double(x) + phase
                let py = Double(y) + phase * 0.37
                let color: (Double, Double, Double)
                switch self {
                case .grid:
                    let tile = (Int(floor(px / 24)) + Int(floor(py / 24))) & 1
                    let line = px.truncatingRemainder(dividingBy: 24) < 2
                        || py.truncatingRemainder(dividingBy: 24) < 2
                    if abs(py - px * 0.6 - 40) < 4 {
                        color = (0.05, 0.44, 0.60)
                    } else if line {
                        color = (0.18, 0.22, 0.26)
                    } else {
                        color = tile == 0 ? (0.89, 0.92, 0.92) : (0.58, 0.70, 0.72)
                    }
                case .stone:
                    // Procedural stone, explicitly synthetic rather than a photograph.
                    let wave = sin(px * 0.021 + sin(py * 0.017) * 2.8)
                    let vein = pow(max(0, 1 - abs(sin(px * 0.009 + py * 0.024 + wave * 0.9))), 14)
                    let grain = sin(px * 1.83 + py * 0.79) * sin(px * 0.67 - py * 1.43) * 0.026
                    let light = 0.83 + wave * 0.055 - vein * 0.22 + grain
                    let warmSide = 0.06 * sin(px * 0.005)
                    color = (light + warmSide, light + 0.015, light + 0.027)
                }
                let offset = (y * width + x) * 4
                bytes[offset] = Self.channel(color.2)
                bytes[offset + 1] = Self.channel(color.1)
                bytes[offset + 2] = Self.channel(color.0)
            }
        }
        return GlassPrototypePixels(width: width, height: height, bytes: bytes)
    }

    private static func channel(_ value: Double) -> UInt8 {
        UInt8((max(0, min(1, value)) * 255).rounded())
    }
}

struct GlassPrototypePixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    func channel(_ channel: Int, x: Int, y: Int) -> Int {
        Int(bytes[(y * width + x) * 4 + channel])
    }

    func image() throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                .union(.byteOrder32Little), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
    }


}

/// The tests use the production Metal pipeline and wait for its command buffer,
/// then blit into CPU-readable memory. No view-cache or timing guess is involved.
final class GlassPrototypeGPU {
    let device: MTLDevice
    let borderRenderer: GlassOpticsRenderer
    let queue: MTLCommandQueue
    private(set) var lastGPUTimeMilliseconds: Double?

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("A Metal device is required to verify physical glass pixels.")
        }
        self.device = device
        borderRenderer = try GlassOpticsRenderer(device: device)
        queue = try XCTUnwrap(device.makeCommandQueue())
    }

    func renderBorder(size: CGSize, scale: Int = 1,
                      optics: GlassBorderOptics = GlassBorderOptics(), time: Float = 0) throws -> GlassPrototypePixels {
        try renderPixels(size: size, scale: scale) { destination, command in
            try borderRenderer.encodeBorder(destination: destination, commandBuffer: command,
                viewSize: size, optics: optics, time: time)
        }
    }

    private func renderPixels(size: CGSize, scale: Int,
        encode: (MTLTexture, MTLCommandBuffer) throws -> Void) throws -> GlassPrototypePixels {
        let width = Int(size.width) * scale
        let height = Int(size.height) * scale
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderWrite, .shaderRead]
        let destination = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        try encode(destination, command)
        let rowBytes = ((width * 4 + 255) / 256) * 256
        let readback = try XCTUnwrap(device.makeBuffer(length: rowBytes * height, options: .storageModeShared))
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: destination, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback,
            destinationOffset: 0, destinationBytesPerRow: rowBytes,
            destinationBytesPerImage: rowBytes * height)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw command.error ?? NSError(domain: "GlassPrototype", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Metal command did not complete."])
        }
        let elapsed = (command.gpuEndTime - command.gpuStartTime) * 1_000
        lastGPUTimeMilliseconds = elapsed.isFinite && elapsed > 0 ? elapsed : nil
        let memory = readback.contents().assumingMemoryBound(to: UInt8.self)
        var packed = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            packed.replaceSubrange((row * width * 4)..<((row + 1) * width * 4),
                with: UnsafeBufferPointer(start: memory + row * rowBytes, count: width * 4))
        }
        return GlassPrototypePixels(width: width, height: height, bytes: packed)
    }
}
