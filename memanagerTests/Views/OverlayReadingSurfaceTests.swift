import AppKit
import SwiftUI
import XCTest
@testable import memanager

@MainActor
final class OverlayReadingSurfaceTests: XCTestCase {
    func testGlassAndLiquidGrainPixelsStayIdenticalAcrossControlActivity() throws {
        let reference = try pixels(style: .glass, activity: .key)
        for style in [BorderShaderStyle.glass, .liquid] {
            for activity in [ControlActiveState.key, .active, .inactive] {
                XCTAssertEqual(try pixels(style: style, activity: activity), reference,
                    "Reading grain must never change when the window gains or loses focus.")
            }
        }
        let centerAlpha = stride(from: 3, to: reference.count, by: 4).map { reference[$0] }
        XCTAssertGreaterThan(centerAlpha.min() ?? 0, 0, "The texture must be present in glass modes.")
        XCTAssertLessThanOrEqual(centerAlpha.max() ?? 255, 10, "Grain must remain a translucent detail.")
        let centerGray = stride(from: 0, to: reference.count, by: 4).map { reference[$0] }
        XCTAssertGreaterThan(Set(centerGray).count, 2, "A solid fill cannot substitute for grain.")
    }

    func testSolidFallbackRemovesGlassGrainInBothAppearances() throws {
        for scheme in [ColorScheme.light, .dark] {
            let glass = try pixels(style: .glass, activity: .key, solid: true, scheme: scheme)
            let none = try pixels(style: .none, activity: .inactive, solid: true, scheme: scheme)
            XCTAssertEqual(glass, none)
            XCTAssertTrue(stride(from: 3, to: glass.count, by: 4).allSatisfy { glass[$0] == 255 })
            XCTAssertEqual(Set(stride(from: 0, to: glass.count, by: 4).map { glass[$0] }).count, 1)
        }
    }

    private func pixels(style: BorderShaderStyle, activity: ControlActiveState,
                        solid: Bool = false, scheme: ColorScheme = .dark) throws -> [UInt8] {
        let renderer = ImageRenderer(content: OverlayReadingSurface(style: style, opacity: 0.75,
            usesSolidFallback: solid).frame(width: 96, height: 96)
            .environment(\.colorScheme, scheme)
            .environment(\.controlActiveState, activity))
        renderer.scale = 1
        renderer.colorMode = .nonLinear
        let image = try XCTUnwrap(renderer.cgImage)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 96, height: 96,
            bitsPerComponent: 8, bytesPerRow: 96 * 4, space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 96, height: 96))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (24..<72).flatMap { y in
            (24..<72).flatMap { x in (0..<4).map { bytes[(y * 96 + x) * 4 + $0] } }
        }
    }
}
