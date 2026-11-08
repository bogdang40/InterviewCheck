import CoreGraphics
import Foundation
import SwiftUI

/// One fixed tile shared by every reading surface. Neither focus nor streamed
/// content regenerates the texture or starts a drawing loop.
enum SurfaceGrain {
    static let image: Image? = {
        let side = 64
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for index in 0..<(side * side) {
            var sample = UInt32(index) &+ 0xA341316C
            sample = (sample ^ (sample >> 16)) &* 0x45D9F3B
            sample = (sample ^ (sample >> 16)) &* 0x45D9F3B
            let gray = UInt8(truncatingIfNeeded: sample ^ (sample >> 16))
            pixels[index * 4] = gray
            pixels[index * 4 + 1] = gray
            pixels[index * 4 + 2] = gray
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: side * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return Image(decorative: image, scale: 1, orientation: .up).interpolation(.none)
    }()
}
