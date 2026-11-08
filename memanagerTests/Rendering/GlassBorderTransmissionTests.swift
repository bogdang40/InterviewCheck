import XCTest
@testable import memanager

final class GlassBorderTransmissionTests: XCTestCase {
    func testMotionChangesGeometryAndLightWithoutChangingTheContentWell() throws {
        let gpu = try GlassPrototypeGPU()
        let size = CGSize(width: 240, height: 180)
        let first = try gpu.renderBorder(size: size, time: 0)
        let later = try gpu.renderBorder(size: size, time: 3)
        XCTAssertNotEqual(first.bytes, later.bytes)
        let staticOptics = GlassBorderOptics(gooey: 0, lightMotion: 0)
        let staticFirst = try gpu.renderBorder(size: size, optics: staticOptics, time: 0)
        let staticLater = try gpu.renderBorder(size: size, optics: staticOptics, time: 3)
        XCTAssertEqual(staticFirst.bytes, staticLater.bytes,
            "Reduced motion must produce identical output as time advances.")
        for pixels in [first, later] {
            for channel in 0..<4 { XCTAssertEqual(pixels.channel(channel, x: 120, y: 90), 0) }
        }
    }

    func testDispersionChangesTransmittedStudioRays() throws {
        let gpu = try GlassPrototypeGPU()
        let size = CGSize(width: 240, height: 180)
        let neutral = try gpu.renderBorder(size: size, scale: 2,
            optics: GlassBorderOptics(dispersion: 0))
        let dispersed = try gpu.renderBorder(size: size, scale: 2,
            optics: GlassBorderOptics(dispersion: 0.07))
        let difference = zip(neutral.bytes, dispersed.bytes).reduce(0) {
            $0 + abs(Int($1.0) - Int($1.1))
        }
        XCTAssertGreaterThan(difference, 100,
            "Distinct RGB ray directions must affect the sampled virtual environment.")
    }

    func testTransmissionContributionPreservesPremultipliedAlphaAndHollowCenter() throws {
        let gpu = try GlassPrototypeGPU()
        let size = CGSize(width: 240, height: 180)
        let reflection = try gpu.renderBorder(size: size,
            optics: GlassBorderOptics(transmissionEnvironmentShare: 0))
        let transmission = try gpu.renderBorder(size: size,
            optics: GlassBorderOptics(transmissionEnvironmentShare: 0.08))
        XCTAssertNotEqual(reflection.bytes, transmission.bytes)
        for offset in stride(from: 0, to: transmission.bytes.count, by: 4) {
            let alpha = transmission.bytes[offset + 3]
            for channel in 0..<3 {
                XCTAssertLessThanOrEqual(transmission.bytes[offset + channel], alpha,
                    "Native source over compositing requires premultiplied color.")
            }
        }
        for (x, y) in [(0, 0), (120, 90), (239, 179)] {
            for channel in 0..<4 {
                XCTAssertEqual(transmission.channel(channel, x: x, y: y), 0)
            }
        }
    }

    func testIOROnePreservesDispersiveReflectionAndExactNeutrality() throws {
        let gpu = try GlassPrototypeGPU()
        let size = CGSize(width: 240, height: 180)
        let neutral = try gpu.renderBorder(size: size, scale: 2,
            optics: GlassBorderOptics(ior: 1, dispersion: 0,
                transmissionEnvironmentShare: 0, gooey: 0, lightMotion: 0))
        let dispersed = try gpu.renderBorder(size: size, scale: 2,
            optics: GlassBorderOptics(ior: 1, dispersion: 0.06,
                transmissionEnvironmentShare: 0, gooey: 0, lightMotion: 0))
        XCTAssertTrue(neutral.bytes.allSatisfy { $0 == 0 },
            "Equal IOR at every wavelength must produce no optical layer.")
        XCTAssertTrue(stride(from: 3, to: dispersed.bytes.count, by: 4).contains {
            dispersed.bytes[$0] > 0
        }, "Blue IOR 1.06 must retain reflection when green and red IOR are 1.")
        for offset in stride(from: 0, to: dispersed.bytes.count, by: 4) {
            for channel in 0..<3 {
                XCTAssertLessThanOrEqual(dispersed.bytes[offset+channel], dispersed.bytes[offset+3])
            }
        }
        for (x,y) in [(0,0), (dispersed.width/2,dispersed.height/2),
                      (dispersed.width-1,dispersed.height-1)] {
            for channel in 0..<4 { XCTAssertEqual(dispersed.channel(channel,x:x,y:y),0) }
        }
    }

    func testOpticalInputBoundaryRejectsInvalidTransmissionParameters() {
        for optics in [GlassBorderOptics(dispersion: -0.01),
                       GlassBorderOptics(dispersion: .infinity),
                       GlassBorderOptics(transmissionEnvironmentShare: .nan),
                       GlassBorderOptics(transmissionEnvironmentShare: 0.36)] {
            XCTAssertThrowsError(try GlassBorderUniforms(viewSize: CGSize(width: 240, height: 180),
                cornerRadius: 36, shoulderWidth: 12, optics: optics))
        }
        XCTAssertEqual(MemoryLayout<GlassBorderUniforms>.stride, 80,
            "The Swift uniform layout must match five Metal float4 fields.")
    }
}
