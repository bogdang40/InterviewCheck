// Draws the InterviewCheck app icon at every macOS size.
// Usage: swift scripts/assets/make-app-icon.swift <AppIcon.appiconset folder>
import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = size / 1024
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: scale, y: scale)

    // Body: Apple's 824 pt rounded square inside a 1024 canvas, with a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28,
                      color: NSColor.black.withAlphaComponent(0.28).cgColor)
    context.addPath(bodyPath)
    context.setFillColor(NSColor(srgbRed: 0.12, green: 0.30, blue: 0.20, alpha: 1).cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(srgbRed: 0.20, green: 0.55, blue: 0.36, alpha: 1).cgColor,
        NSColor(srgbRed: 0.09, green: 0.27, blue: 0.18, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Faint waveform behind the shield: the app listens to the call.
    context.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    let bars: [CGFloat] = [120, 220, 330, 200, 280, 170, 110]
    for (index, height) in bars.enumerated() {
        let x = 180 + CGFloat(index) * 104
        context.addPath(CGPath(roundedRect: CGRect(x: x, y: 512 - height / 2, width: 48, height: height),
                               cornerWidth: 24, cornerHeight: 24, transform: nil))
    }
    context.fillPath()
    context.restoreGState()

    // Shield.
    let shield = CGMutablePath()
    shield.move(to: CGPoint(x: 512, y: 800))
    shield.addCurve(to: CGPoint(x: 300, y: 720), control1: CGPoint(x: 440, y: 760), control2: CGPoint(x: 370, y: 735))
    shield.addLine(to: CGPoint(x: 300, y: 520))
    shield.addCurve(to: CGPoint(x: 512, y: 220), control1: CGPoint(x: 300, y: 380), control2: CGPoint(x: 400, y: 280))
    shield.addCurve(to: CGPoint(x: 724, y: 520), control1: CGPoint(x: 624, y: 280), control2: CGPoint(x: 724, y: 380))
    shield.addLine(to: CGPoint(x: 724, y: 720))
    shield.addCurve(to: CGPoint(x: 512, y: 800), control1: CGPoint(x: 654, y: 735), control2: CGPoint(x: 584, y: 760))
    shield.closeSubpath()
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 18,
                      color: NSColor.black.withAlphaComponent(0.25).cgColor)
    context.addPath(shield)
    context.setFillColor(NSColor(srgbRed: 0.98, green: 0.97, blue: 0.93, alpha: 1).cgColor)
    context.fillPath()
    context.restoreGState()

    // Check mark.
    let check = CGMutablePath()
    check.move(to: CGPoint(x: 405, y: 515))
    check.addLine(to: CGPoint(x: 485, y: 435))
    check.addLine(to: CGPoint(x: 630, y: 600))
    context.addPath(check)
    context.setStrokeColor(NSColor(srgbRed: 0.16, green: 0.47, blue: 0.30, alpha: 1).cgColor)
    context.setLineWidth(58)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256), ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512), ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in sizes {
    let data = drawIcon(size: size).representation(using: .png, properties: [:])!
    try! data.write(to: folder.appendingPathComponent(name))
    print("wrote \(name)")
}
