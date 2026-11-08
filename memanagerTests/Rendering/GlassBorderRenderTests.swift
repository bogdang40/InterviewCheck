import AppKit
import XCTest
@testable import memanager

final class GlassBorderRenderTests: XCTestCase {
    private let size = CGSize(width: 240, height: 180)

    func testBorderLeavesCenterAndRoundedExteriorTransparentAtBothScales() throws {
        let gpu = try GlassPrototypeGPU()
        for scale in [1, 2] {
            let pixels = try gpu.renderBorder(size: size, scale: scale)
            for (x, y) in [(0, 0), (239, 0), (0, 179), (239, 179), (120, 90), (40, 40), (200, 140)] {
                for channel in 0..<4 {
                    XCTAssertEqual(pixels.channel(channel, x: x * scale, y: y * scale), 0,
                        "The edge layer must not obscure native glass or the reading surface.")
                }
            }
            let edgeAlpha = (2..<10).reduce(0) { $0 + pixels.channel(3, x: $1 * scale, y: 90 * scale) }
            XCTAssertGreaterThan(edgeAlpha, 0, "A finite glass shoulder must contribute reflection.")
        }
    }

    func testNoInterfaceOrReflectionProducesNoPaintedOutline() throws {
        let gpu = try GlassPrototypeGPU()
        for optics in [GlassBorderOptics(ior: 1, dispersion: 0), GlassBorderOptics(thickness: 0),
                       GlassBorderOptics(reflectionStrength: 0)] {
            let pixels = try gpu.renderBorder(size: size, optics: optics)
            XCTAssertTrue(pixels.bytes.allSatisfy { $0 == 0 },
                "There must be no decorative outline independent of the optical interface.")
        }
    }

    func testDirectionalLightingAndRoughnessAreDeterministic() throws {
        let gpu = try GlassPrototypeGPU()
        let smooth = try gpu.renderBorder(size: size, optics: GlassBorderOptics(roughness: 0))
        let rough = try gpu.renderBorder(size: size, optics: GlassBorderOptics(roughness: 0.03))
        let repeated = try gpu.renderBorder(size: size, optics: GlassBorderOptics(roughness: 0.03))
        XCTAssertEqual(rough.bytes, repeated.bytes, "Surface roughness must not flicker between identical frames.")
        XCTAssertNotEqual(smooth.bytes, rough.bytes, "Roughness must change the reflected lighting.")
        let directionalDifference = (2..<10).reduce(0) { total, depth in
            total + (0..<3).reduce(0) {
                $0 + abs(smooth.channel($1, x: 120, y: depth)
                    - smooth.channel($1, x: 120, y: 179 - depth))
            }
        }
        XCTAssertGreaterThan(directionalDifference, 5,
            "Opposite surface normals should sample different parts of the declared lighting environment.")
    }

    func testRolledShoulderHasTwoSymmetricInterfacesAndRespondsToThickness() throws {
        let gpu = try GlassPrototypeGPU()
        let thin = try gpu.renderBorder(size: size, scale: 2,
            optics: GlassBorderOptics(thickness: 10, roughness: 0, gooey: 0, lightMotion: 0))
        let thick = try gpu.renderBorder(size: size, scale: 2,
            optics: GlassBorderOptics(thickness: 18, roughness: 0, gooey: 0, lightMotion: 0))
        // The centers of these pixels are 0.25pt and 11.75pt into a 12pt bead.
        let outerAlpha = thick.channel(3, x: 0, y: 180)
        let innerAlpha = thick.channel(3, x: 23, y: 180)
        XCTAssertLessThanOrEqual(abs(outerAlpha - innerAlpha), 1,
            "Both sides of the rolled bead must preserve grazing reflection.")
        XCTAssertGreaterThan(outerAlpha, thick.channel(3, x: 12, y: 180),
            "A curved shoulder must reflect more at grazing angles than at normal incidence.")
        XCTAssertGreaterThan(outerAlpha, thin.channel(3, x: 0, y: 180),
            "Increasing bead thickness must change the surface slope and its reflection.")
    }

    @MainActor
    func testExportNativeBorderPrototype() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MEMANAGER_GLASS_PROTOTYPE"] == "1",
            "Native border proof is opt in.")
        let gpu = try GlassPrototypeGPU()
        let directory = try OverlayRenderHarness.outputDirectory()
        // This GPU readback fixture deliberately specifies outer glass geometry.
        let panelSize = CGSize(width: 720, height: 700)
        _ = try gpu.renderBorder(size: panelSize, scale: 2)
        let border = try gpu.renderBorder(size: panelSize, scale: 2)
        let gpuMilliseconds = gpu.lastGPUTimeMilliseconds
        let image = try border.image()
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("glass-border-transparent.png"))
        let sceneName = ProcessInfo.processInfo.environment["MEMANAGER_GLASS_PREVIEW_SCENE"] ?? "grid"
        let previewScene: GlassPrototypeScene = sceneName == "stone" ? .stone : .grid
        var metadata: [String: Any] = [
            "renderer": "Production GlassOpticsRenderer.encodeBorder",
            "evidence": "Transparent border GPU readback after command completion; no source texture",
            "nativePreview": "Actual OverlayGlassHost above an owned backdrop sibling in one non-key window",
            "previewScene": previewScene.rawValue,
            "content": "Enabled production controls with local payment retry sample, empty actions and zero focus nonces",
            "desktopCaptureRequested": false,
            "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            "increaseContrast": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            "limitation": "The transparent PNG proves edge pixels only. Native material requires the visible preview.",
            "widthPixels": border.width, "heightPixels": border.height,
            "backingScale": 2,
            "gpuTimingScope": "One warm command at 720x700 points, 2x: border compute plus readback blit; excludes CPU layout and allocation"
        ]
        if let gpuMilliseconds { metadata["gpuDurationMilliseconds"] = gpuMilliseconds }
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("glass-border-evidence.json"))
        print("GLASS_BORDER_EXPORTED \(directory.path)/glass-border-transparent.png")
        let theme = ProcessInfo.processInfo.environment["MEMANAGER_GLASS_PREVIEW_APPEARANCE"] ?? "light"
        let appearances: [OverlayAppearance] = theme == "both" ? [.light, .dark]
            : [theme == "dark" ? .dark : .light]
        let margin = GlassPrototypeArtifacts.margin
        for appearance in appearances {
            if let nativeEvidence = try await GlassPrototypePreview.present(
                contentSize: GlassPrototypeArtifacts.contentSize, margin: margin,
                appearance: appearance, content: GlassPrototypeArtifacts.makeShell(appearance: appearance),
                backdrop: previewScene) {
                metadata["nativeMetal-\(appearance.rawValue)"] = nativeEvidence
                try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent("glass-border-evidence.json"))
            }
        }
    }
}
