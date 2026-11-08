import AppKit
import SwiftUI
import XCTest
@testable import memanager

@MainActor
final class NoneSurfaceTests: XCTestCase {
    func testRasterPreservesSolidPaletteColorsInEachAppearance() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua,
                     .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            for color in [OverlayPalette.backdropBase, OverlayPalette.textPrimary, OverlayPalette.textSecondary] {
                let expected = try resolved(color, appearance: appearance)
                let pixels = try raster(color, appearance: appearance)
                let maximumError = pixels.map { $0.maximumChannelDifference(from: expected) }.max() ?? 1
                XCTAssertLessThanOrEqual(maximumError, 2.0 / 255,
                    "The raster must preserve sRGB source colors before measuring contrast in \(name.rawValue).")
            }
        }
    }

    func testPrimaryAndSecondaryTextStayReadableOverBlackAndWhiteAtMinimumOpacity() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            for (backdropName, backdrop) in [("black", Color.black), ("white", Color.white)] {
                let pixels = try render(opacity: 0.5, solid: false, backdrop: backdrop, appearance: appearance)
                for (textName, foreground) in [("primary", OverlayPalette.textPrimary),
                                               ("secondary", OverlayPalette.textSecondary)] {
                    let text = try resolved(foreground, appearance: appearance)
                    let minimum = pixels.map { contrast(text, $0) }.min() ?? 0
                    let scenario = "\(name.rawValue), \(backdropName) backdrop, \(textName) text"
                    print("NONE_SURFACE_CONTRAST \(scenario): minimum=\(String(format: "%.3f", minimum))")
                    XCTAssertGreaterThanOrEqual(minimum, 4.5,
                        "Minimum across all grain samples for \(scenario).")
                }
            }
        }
    }

    func testOpacityStillChangesTransmissionAndSolidFallbackRemovesGrain() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let isDark = name == .darkAqua
            let backdrop = isDark ? Color.white : .black
            let low = try render(opacity: 0.5, solid: false, backdrop: backdrop, appearance: appearance)
            let high = try render(opacity: 1, solid: false, backdrop: backdrop, appearance: appearance)
            let solid = try render(opacity: .nan, solid: true, backdrop: backdrop, appearance: appearance)
            let base = try resolved(OverlayPalette.backdropBase, appearance: appearance)
            let direction = isDark ? 1.0 : -1.0
            let minimumChange = zip(low, high).map { pair in
                direction * (pair.0.luminance - pair.1.luminance)
            }.min() ?? 0
            let minimumTransmission = high.map { direction * ($0.luminance - base.luminance) }.min() ?? 0
            let maximumSolidError = solid.map { $0.maximumChannelDifference(from: base) }.max() ?? 1
            XCTAssertGreaterThan(minimumChange, 0, "The opacity slider must retain its effect in \(name.rawValue).")
            XCTAssertGreaterThan(minimumTransmission, 0, "Standard None must still transmit some backdrop.")
            XCTAssertLessThanOrEqual(maximumSolidError, 2.0 / 255,
                "Solid fallback must remove both grain and backdrop transmission in \(name.rawValue).")
            let grainRange = (low.map(\.red).max() ?? 0) - (low.map(\.red).min() ?? 0)
            XCTAssertGreaterThan(grainRange, 0, "Standard None retains its fixed grain.")
            XCTAssertLessThanOrEqual(grainRange, 0.03, "The grain must remain subtle.")
        }
    }

    private func render(opacity: Double, solid: Bool, backdrop: Color,
                        appearance: NSAppearance) throws -> [RGB] {
        try raster(NoneSurface(opacity: opacity, usesSolidFallback: solid).background(backdrop),
                   appearance: appearance)
    }

    private func raster<Content: View>(_ content: Content, appearance: NSAppearance) throws -> [RGB] {
        let side = 96
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: content.frame(width: CGFloat(side), height: CGFloat(side))
                .environment(\.colorScheme, isDark ? .dark : .light))
            renderer.scale = 1
            renderer.colorMode = .nonLinear
            renderer.isOpaque = true
            image = renderer.cgImage
        }
        // cacheDisplay uses a display-dependent bitmap profile. Comparing its
        // colorAt values with sRGB tokens can fail even for an opaque swatch.
        // None is pure SwiftUI, so render it directly into a tagged sRGB bitmap.
        let source = try XCTUnwrap(image)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        // More than one complete grain tile, safely inside the rounded corners.
        return (24..<72).flatMap { y in
            (24..<72).map { x in
                let offset = (y * side + x) * 4
                return RGB(red: Double(bytes[offset]) / 255, green: Double(bytes[offset + 1]) / 255,
                           blue: Double(bytes[offset + 2]) / 255)
            }
        }
    }

    private func resolved(_ color: Color, appearance: NSAppearance) throws -> RGB {
        var native: NSColor?
        appearance.performAsCurrentDrawingAppearance { native = NSColor(color).usingColorSpace(.sRGB) }
        let value = try XCTUnwrap(native)
        return RGB(red: Double(value.redComponent), green: Double(value.greenComponent),
                   blue: Double(value.blueComponent))
    }

    private func contrast(_ first: RGB, _ second: RGB) -> Double {
        let a = first.luminance, b = second.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

private struct RGB {
    let red: Double
    let green: Double
    let blue: Double

    var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return linear(red) * 0.2126 + linear(green) * 0.7152 + linear(blue) * 0.0722
    }

    func maximumChannelDifference(from other: RGB) -> Double {
        max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue))
    }
}
