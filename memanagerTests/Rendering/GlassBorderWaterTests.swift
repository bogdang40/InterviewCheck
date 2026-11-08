import XCTest
@testable import memanager

final class GlassBorderWaterTests: XCTestCase {
    func testWaterChangesSurfaceWithContourAndTravelingLightDisabled() throws {
        let gpu = try GlassPrototypeGPU()
        let size = CGSize(width: 240, height: 180)
        let calm = GlassBorderOptics(ior: 1.333, dispersion: 0.006, gooey: 0, lightMotion: 0)
        var water = calm
        water.liquid = 1
        let calmStart = try gpu.renderBorder(size: size, optics: calm, time: 0)
        let calmLater = try gpu.renderBorder(size: size, optics: calm, time: 2)
        let waterStart = try gpu.renderBorder(size: size, optics: water, time: 0)
        let waterLater = try gpu.renderBorder(size: size, optics: water, time: 2)
        XCTAssertEqual(calmStart.bytes, calmLater.bytes)
        XCTAssertNotEqual(waterStart.bytes, waterLater.bytes)
        let changedCoverageOrFresnel = stride(from: 3, to: waterStart.bytes.count, by: 4)
            .filter { waterStart.bytes[$0] != waterLater.bytes[$0] }.count
        XCTAssertGreaterThan(changedCoverageOrFresnel, 100,
            "Water motion must change surface slopes, not only a traveling RGB light.")
        let frozen = try gpu.renderBorder(size: size, optics: water, time: 0)
        XCTAssertEqual(waterStart.bytes, frozen.bytes,
            "Fixed time preserves static ripples for Reduce Motion.")
    }

    func testWaterRemainsPremultipliedAndConfinedToTheGutterAtBothScales() throws {
        let gpu = try GlassPrototypeGPU()
        let water = try XCTUnwrap(BorderShaderStyle.liquid.optics)
        for scale in [1, 2] {
            let pixels = try gpu.renderBorder(size: CGSize(width: 240, height: 180),
                scale: scale, optics: water, time: 2.3)
            for offset in stride(from: 0, to: pixels.bytes.count, by: 4) {
                for channel in 0..<3 {
                    XCTAssertLessThanOrEqual(pixels.bytes[offset + channel], pixels.bytes[offset + 3])
                }
            }
            for (x, y) in [(0, 0), (239, 179), (120, 90), (40, 40), (200, 140)] {
                for channel in 0..<4 {
                    XCTAssertEqual(pixels.channel(channel, x: x * scale, y: y * scale), 0)
                }
            }
        }
    }

    func testWaterAmplitudeRejectsNonfiniteAndOutOfRangeInputs() {
        for amplitude: Float in [-0.01, 1.01, .nan, .infinity] {
            XCTAssertThrowsError(try GlassBorderUniforms(viewSize: CGSize(width: 240, height: 180),
                cornerRadius: 36, shoulderWidth: 12, optics: GlassBorderOptics(liquid: amplitude)))
        }
    }
}
