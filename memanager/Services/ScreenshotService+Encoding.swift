import AppKit
import SwiftUI

extension ScreenshotService {
    private func resizeImage(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        let originalSize = image.size
        let widthRatio = maxDimension / originalSize.width
        let heightRatio = maxDimension / originalSize.height
        let ratio = min(widthRatio, heightRatio, 1.0)  // Don't upscale

        if ratio >= 1.0 {
            return image  // No resize needed
        }

        let newSize = NSSize(
            width: originalSize.width * ratio,
            height: originalSize.height * ratio
        )

        let resizedImage = NSImage(size: newSize)
        resizedImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: originalSize),
                   operation: .copy,
                   fraction: 1.0)
        resizedImage.unlockFocus()

        logDebug("Resized image from \(Int(originalSize.width))x\(Int(originalSize.height)) to \(Int(newSize.width))x\(Int(newSize.height))")
        return resizedImage
    }

    /// Convert image to compressed JPEG base64 string
    func imageToCompressedBase64(_ image: NSImage) -> String? {
        // Resize first
        let resized = resizeImage(image, maxDimension: maxImageDimension)

        guard let tiffData = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality]) else {
            return nil
        }

        let base64 = jpegData.base64EncodedString()
        logDebug("Compressed image: \(jpegData.count / 1024)KB base64 length: \(base64.count)")
        return base64
    }
}
