import AppKit
import SwiftUI
import XCTest
@testable import memanager

/// Opt-in captures of the actual Appearance page with every border selection.
@MainActor
final class AppearanceBorderRenderTests: XCTestCase {
    func testAppearanceBorderSelectorAtCompactAndRegularWidths() async throws {
        try await withSelections { style, width in
            try await OverlayRenderHarness.render("appearance-border-\(style.rawValue)-\(Int(width))",
                size: CGSize(width: width, height: 1000)) {
                SettingsScreen(initialPane: .appearance)
            }
        }
    }

    func testBorderShaderControlAtCompactAndRegularWidths() async throws {
        try await withSelections { style, width in
            try await OverlayRenderHarness.render("border-selector-\(style.rawValue)-\(Int(width))",
                size: CGSize(width: width, height: style == .none ? 190 : width < 560 ? 1520 : 1140)) {
                BorderShaderSettingsSection(selection: Binding(
                    get: { SettingsManager.shared.borderShaderStyle },
                    set: { SettingsManager.shared.borderShaderStyle = $0 }),
                    configuration: Binding(
                        get: { SettingsManager.shared.configuration(for: style) ?? .liquidDefault },
                        set: { SettingsManager.shared.updateConfiguration($0, for: style) }),
                    onReset: { SettingsManager.shared.resetConfiguration(for: style) })
                    .padding(OverlayLayout.stageInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .environment(\.settingsBreakpoint, OverlayLayout.breakpoint(for: width))
            }
        }
    }

    func testCustomizedBorderControlsAtCompactWidth() async throws {
        try OverlayRenderHarness.skipUnlessEnabled()
        var configuration = BorderShaderConfiguration.liquidDefault
        configuration.width = 36
        configuration.depth = 12
        configuration.ior = 1.8
        configuration.dispersion = 0.042
        configuration.fluidity = 0.25
        configuration.lightStrength = 0.45
        configuration.motionSpeed = 1.5
        configuration.animationEnabled = false
        try await OverlayRenderHarness.render("border-controls-custom-400", size: CGSize(width: 400, height: 1520)) {
            BorderShaderSettingsSection(selection: .constant(.liquid),
                configuration: .constant(configuration), onReset: {})
                .padding(OverlayLayout.stageInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .environment(\.settingsBreakpoint, .compact)
        }
    }

    private func withSelections(_ render: (BorderShaderStyle, CGFloat) async throws -> Void) async throws {
        try OverlayRenderHarness.skipUnlessEnabled()
        let settings = SettingsManager.shared
        let original = settings.borderShaderStyle
        let persisted = AppDefaults.standard.object(forKey: "memanager.borderShaderStyle")
        defer {
            settings.borderShaderStyle = original
            if let persisted { AppDefaults.standard.set(persisted, forKey: "memanager.borderShaderStyle") }
            else { AppDefaults.standard.removeObject(forKey: "memanager.borderShaderStyle") }
        }
        for style in BorderShaderStyle.allCases {
            settings.borderShaderStyle = style
            for width: CGFloat in [400, 560] {
                try await render(style, width)
            }
        }
    }
}
