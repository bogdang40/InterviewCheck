import AppKit
import SwiftUI
import XCTest
@testable import memanager

@MainActor
final class OverlayAppearanceTests: XCTestCase {
    func testRestorationAndExplicitSystemBehavior() {
        XCTAssertEqual(OverlayAppearance.restored(from: nil), .system)
        XCTAssertEqual(OverlayAppearance.restored(from: "obsolete"), .system)
        XCTAssertEqual(OverlayAppearance.restored(from: "light"), .light)
        XCTAssertEqual(OverlayAppearance.restored(from: "dark"), .dark)
        XCTAssertNil(OverlayAppearance.system.nativeAppearance)
        XCTAssertNil(OverlayAppearance.system.colorScheme)
        XCTAssertEqual(OverlayAppearance.light.nativeAppearance?.name, .aqua)
        XCTAssertEqual(OverlayAppearance.dark.nativeAppearance?.name, .darkAqua)
    }

    func testChoiceUpdatesNativePanelAndPersistsWithoutChangingSessionSettings() {
        let settings = SettingsManager.shared
        let original = settings.overlayAppearance
        let width = settings.overlayWidth
        let font = settings.fontSize
        let audio = settings.captureSystemAudio
        let window = OverlayWindow()
        defer { settings.overlayAppearance = original; window.close() }
        for choice in OverlayAppearance.allCases {
            settings.overlayAppearance = choice
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            XCTAssertEqual(window.appearance?.name, choice.nativeAppearance?.name)
            XCTAssertEqual(AppDefaults.standard.string(forKey: "memanager.overlayAppearance"), choice.rawValue)
        }
        XCTAssertEqual(settings.overlayWidth, width)
        XCTAssertEqual(settings.fontSize, font)
        XCTAssertEqual(settings.captureSystemAudio, audio)
    }

    func testFallbackTextAndPrimaryActionsMeetContrastBenchmarkInBothAppearances() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: name)!
            for foreground in [OverlayPalette.textPrimary, OverlayPalette.textSecondary, OverlayPalette.textTertiary] {
                XCTAssertGreaterThanOrEqual(contrast(foreground, OverlayPalette.backdropBase, appearance), 4.5, "\(name)")
            }
            XCTAssertGreaterThanOrEqual(contrast(OverlayPalette.onPrimaryAction, OverlayPalette.primaryAction, appearance), 4.5)
        }
    }

    func testReadingVeilTransmitsBackdropInStandardAppearances() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                      || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
                      "The system correctly requires an opaque accessibility fallback.")
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: name)!
            appearance.performAsCurrentDrawingAppearance {
                let color = NSColor(OverlayPalette.readingSurface).usingColorSpace(.sRGB)!
                XCTAssertEqual(color.alphaComponent, 0.10, accuracy: 0.001)
            }
        }
    }

    private func contrast(_ first: Color, _ second: Color, _ appearance: NSAppearance) -> Double {
        let a = luminance(first, appearance)
        let b = luminance(second, appearance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func luminance(_ value: Color, _ appearance: NSAppearance) -> Double {
        var native: NSColor!
        appearance.performAsCurrentDrawingAppearance {
            native = NSColor(value).usingColorSpace(.sRGB)
        }
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return linear(native.redComponent) * 0.2126 + linear(native.greenComponent) * 0.7152 + linear(native.blueComponent) * 0.0722
    }
}
