import AppKit

enum ScreenCaptureGeometry {
    static func displayRect(for screen: NSScreen) -> CGRect? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
    }

    /// Region selection uses local AppKit coordinates; Quartz uses the
    /// selected display's global origin with its vertical axis reversed.
    static func region(_ localRect: CGRect, in displayRect: CGRect) -> CGRect? {
        guard [localRect.minX, localRect.minY, localRect.width, localRect.height,
               displayRect.minX, displayRect.minY, displayRect.width, displayRect.height]
            .allSatisfy(\.isFinite),
              localRect.width > 0, localRect.height > 0,
              displayRect.width > 0, displayRect.height > 0 else { return nil }
        let clipped = localRect.intersection(CGRect(origin: .zero, size: displayRect.size))
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        return CGRect(x: displayRect.minX + clipped.minX,
                      y: displayRect.minY + displayRect.height - clipped.maxY,
                      width: clipped.width, height: clipped.height)
    }
}
