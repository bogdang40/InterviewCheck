import XCTest
@testable import memanager

final class BorderShaderConfigurationTests: XCTestCase {
    func testDefaultsPreserveBothMaterialsAndNoneHasNoConfiguration() throws {
        let glass = BorderShaderConfiguration.glassDefault
        let liquid = BorderShaderConfiguration.liquidDefault
        XCTAssertEqual(glass.width, 6)
        XCTAssertEqual(liquid.width, 6)
        XCTAssertEqual(glass.depth, 3.891525487558091, accuracy: 0.000001)
        XCTAssertEqual(liquid.depth, 4.590312174568466, accuracy: 0.000001)
        XCTAssertEqual(glass.optics.ior, 1.65, accuracy: 0.0001)
        XCTAssertEqual(glass.optics.liquid, 0)
        XCTAssertEqual(liquid.optics.ior, 1.333, accuracy: 0.0001)
        XCTAssertEqual(liquid.optics.liquid, 1)
        XCTAssertNil(BorderShaderConfiguration.preset(for: .none))
        try withStore { store in
            XCTAssertEqual(store.load(for: .glass), glass)
            XCTAssertEqual(store.load(for: .liquid), liquid)
        }
        for config in [glass, liquid] {
            _ = try GlassBorderUniforms(viewSize: CGSize(width: 320, height: 240),
                cornerRadius: 36, shoulderWidth: config.width, optics: config.optics)
        }
    }

    func testEveryDialRoundTripsIndependentlyForEachMaterial() throws {
        try withStore { store in
            let glass = BorderShaderConfiguration(width: 24, depth: 12, ior: 1.75,
                dispersion: 0.025, roughness: 0.045, fluidity: 0.3, waterRipples: 0.4,
                reflectionStrength: 0.6, transmissionShare: 0.15, lightStrength: 0.22,
                animationEnabled: false, motionSpeed: 1.4)
            let liquid = BorderShaderConfiguration(width: 9, depth: 4, ior: 1.31,
                dispersion: 0.004, roughness: 0.05, fluidity: 0.2, waterRipples: 0.7,
                reflectionStrength: 0.35, transmissionShare: 0.2, lightStrength: 0.9,
                animationEnabled: false, motionSpeed: 0.4)
            try store.save(glass, for: .glass)
            try store.save(liquid, for: .liquid)
            let restored = BorderShaderConfigurationStore(defaults: store.defaults)
            XCTAssertEqual(restored.load(for: .glass), glass)
            XCTAssertEqual(restored.load(for: .liquid), liquid)
            var changedGlass = glass
            changedGlass.width = 40
            try store.save(changedGlass, for: .glass)
            XCTAssertEqual(restored.load(for: .glass), changedGlass)
            XCTAssertEqual(restored.load(for: .liquid), liquid)
            try store.save(.glassDefault, for: .glass)
            XCTAssertEqual(restored.load(for: .glass), .glassDefault)
            XCTAssertEqual(restored.load(for: .liquid), liquid)
        }
    }

    func testNoneCannotOverwriteEitherSavedMaterial() throws {
        try withStore { store in
            let glass = BorderShaderConfiguration(width: 28)
            let liquid = BorderShaderConfiguration(width: 8, depth: 4, waterRipples: 1)
            try store.save(glass, for: .glass)
            try store.save(liquid, for: .liquid)
            XCTAssertNil(try store.save(BorderShaderConfiguration(width: 48), for: .none))
            XCTAssertNil(store.load(for: .none))
            XCTAssertEqual(store.load(for: .glass), glass)
            XCTAssertEqual(store.load(for: .liquid), liquid)
        }
    }

    func testInvalidValuesAreBoundedBeforeTheyReachMetal() throws {
        let input = BorderShaderConfiguration(width: .nan, depth: .infinity, ior: 8,
            dispersion: 1, roughness: 5, fluidity: -4, waterRipples: 7,
            reflectionStrength: 2, transmissionShare: -3, lightStrength: .nan,
            animationEnabled: false, motionSpeed: 0)
        let valid = input.sanitized(fallback: .liquidDefault)
        XCTAssertEqual(valid.width, 6)
        XCTAssertEqual(valid.depth, 3.1350309805416545, accuracy: 0.000001,
            "Maximum water curvature and IOR require a shallower dome than the fallback depth.")
        XCTAssertEqual(valid.ior, 2.2)
        XCTAssertEqual(valid.dispersion, 0.06)
        XCTAssertEqual(valid.roughness, 0.08)
        XCTAssertEqual(valid.fluidity, 0)
        XCTAssertEqual(valid.waterRipples, 1)
        XCTAssertEqual(valid.reflectionStrength, 1)
        XCTAssertEqual(valid.transmissionShare, 0)
        XCTAssertEqual(valid.lightStrength, 0.8)
        XCTAssertEqual(valid.motionSpeed, 0.1)
        XCTAssertFalse(valid.animationEnabled)
        _ = try GlassBorderUniforms(viewSize: CGSize(width: 320, height: 240),
            cornerRadius: 36, shoulderWidth: valid.width, optics: valid.optics)
    }

    func testDepthBoundPreventsFocalInversionAcrossTheControlRange() throws {
        for width in [2.0, 6, 12, 24, 48] {
            for ior in [1.0, 1.333, 1.65, 2.2] {
                for dispersion in [0.0, 0.006, 0.06] {
                    let config = BorderShaderConfiguration(width: width, depth: 30,
                        ior: ior, dispersion: dispersion).sanitized()
                    let ratio = config.depth / (width / 2)
                    let derivative = 1 - (1 - 1 / max(1.0001, ior + dispersion)) * ratio * ratio
                    XCTAssertGreaterThanOrEqual(derivative, 0.30 - 0.000001)
                    XCTAssertLessThanOrEqual(config.depth, config.maximumDepth)
                    XCTAssertEqual(Double(config.optics.thickness), config.depth * 2, accuracy: 0.00001)
                    _ = try GlassBorderUniforms(viewSize: CGSize(width: 320, height: 240),
                        cornerRadius: 36, shoulderWidth: width, optics: config.optics)
                }
            }
        }
    }

    func testWaterCurvatureCapPreservesPresetsAndSupportedMinimumDepth() {
        let folded = BorderShaderConfiguration(width: 48, depth: 30, ior: 2.2,
            dispersion: 0.06, fluidity: 1, waterRipples: 1)
        XCTAssertGreaterThan(folded.maximumDepth, 13)
        XCTAssertLessThan(folded.maximumDepth, 13.02)
        XCTAssertEqual(BorderShaderConfiguration.glassDefault.sanitized(), .glassDefault)
        XCTAssertEqual(BorderShaderConfiguration.liquidDefault.sanitized(), .liquidDefault)
        let mixed = BorderShaderConfiguration(width: 24, depth: 12, ior: 1.75,
            dispersion: 0.025, fluidity: 0.3, waterRipples: 0.4)
        XCTAssertEqual(mixed.sanitized().depth, 12)
        for ior in [1.0, 1.333, 2.2] {
            for fluidity in [0.0, 0.5, 1] {
                for water in [0.0, 0.5, 1] {
                    let config = BorderShaderConfiguration(width: 2, depth: 1, ior: ior,
                        dispersion: 0.06, fluidity: fluidity, waterRipples: water)
                    XCTAssertGreaterThanOrEqual(config.maximumDepth, 1)
                    XCTAssertEqual(config.sanitized().depth, 1)
                }
            }
        }
    }

    func testDepthUsesSanitizedMotionFieldsBeforeApplyingItsLimit() {
        let invalid = BorderShaderConfiguration(width: 48, depth: 30,
            fluidity: .nan, waterRipples: .infinity)
        let valid = invalid.sanitized(fallback: .liquidDefault)
        XCTAssertEqual(valid.fluidity, BorderShaderConfiguration.liquidDefault.fluidity)
        XCTAssertEqual(valid.waterRipples, 1)
        XCTAssertLessThanOrEqual(valid.depth, valid.maximumDepth)
    }

    func testCorruptStorageRestoresOnlyItsOwnMaterialPreset() throws {
        try withStore { store in
            let glass = BorderShaderConfiguration(width: 30, reflectionStrength: 0.5)
            try store.save(glass, for: .glass)
            store.defaults.set(Data("invalid configuration".utf8),
                forKey: "memanager.borderShader.liquidConfiguration")
            XCTAssertEqual(store.load(for: .glass), glass)
            XCTAssertEqual(store.load(for: .liquid), .liquidDefault)
        }
    }

    private func withStore(_ body: (BorderShaderConfigurationStore) throws -> Void) throws {
        let suite = "BorderShaderConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(BorderShaderConfigurationStore(defaults: defaults))
    }
}
