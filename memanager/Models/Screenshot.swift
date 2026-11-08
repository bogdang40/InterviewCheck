import AppKit
import Foundation

struct Screenshot: Identifiable {
    let id = UUID()
    let image: NSImage
    let capturedAt: Date

    var thumbnail: NSImage {
        let targetSize = NSSize(width: 120, height: 80)
        let newImage = NSImage(size: targetSize)

        newImage.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        newImage.unlockFocus()

        return newImage
    }

    var base64: String? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return pngData.base64EncodedString()
    }
}
