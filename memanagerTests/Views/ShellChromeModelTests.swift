import XCTest
@testable import memanager

/// Models behind the command bar and status bar chrome.
final class ShellChromeModelTests: XCTestCase {

    // MARK: Key caps

    func testKeyCapGlyphsForCommonChords() {
        XCTAssertEqual(KeyCapFormatter.glyphs(for: "Cmd+Shift+S"), "⌘⇧S")
        XCTAssertEqual(KeyCapFormatter.glyphs(for: "Cmd+/"), "⌘/")
        XCTAssertEqual(KeyCapFormatter.glyphs(for: "Cmd+Option+Left/Right"), "⌘⌥←/→")
        XCTAssertEqual(KeyCapFormatter.glyphs(for: "Cmd+Shift+Return"), "⌘⇧↩")
        XCTAssertEqual(KeyCapFormatter.glyphs(for: "Escape"), "⎋")
        XCTAssertEqual(KeyCapFormatter.glyphs(for: "Cmd+1-5"), "⌘1…5")
    }

    // MARK: Session pill

    func testCaptureStatusRemainsVisibleDuringGeneration() {
        XCTAssertEqual(SessionPillModel(state: .listening, isRecording: true, isLoading: true, isStreaming: true).dotState, .recording)
        XCTAssertEqual(SessionPillModel(state: .listening, isRecording: true, isLoading: true, isStreaming: false).dotState, .recording)
        XCTAssertEqual(SessionPillModel(state: .listening, isRecording: true, isLoading: false, isStreaming: false).dotState, .recording)
        XCTAssertEqual(SessionPillModel(state: .listening, isRecording: false, isLoading: false, isStreaming: false).dotState, .error)
        XCTAssertEqual(SessionPillModel(state: .paused, isRecording: false, isLoading: false, isStreaming: false).dotState, .paused)
        XCTAssertEqual(SessionPillModel(state: .idle, isRecording: false, isLoading: false, isStreaming: false).dotState, .idle)
        XCTAssertEqual(SessionPillModel(state: .listening, isRecording: false, isLoading: true, isStreaming: false).label, "Capture unavailable")
        XCTAssertEqual(SessionPillModel(state: .paused, isRecording: false, isLoading: true, isStreaming: true).label, "Paused")
    }

    func testPillShowsElapsedOnlyWhileASessionExists() {
        XCTAssertFalse(SessionPillModel(state: .idle, isRecording: false, isLoading: false, isStreaming: false).showsElapsed)
        XCTAssertTrue(SessionPillModel(state: .paused, isRecording: false, isLoading: false, isStreaming: false).showsElapsed)
    }

    // MARK: Pacing badge

    func testPacingBadgeHidesWhenDisabledOrLowConfidence() {
        XCTAssertNil(PacingBadgeModel(state: .decisive(confidence: 0.9), enabled: false))
        XCTAssertNil(PacingBadgeModel(state: .decisive(confidence: 0.1), enabled: true))
        XCTAssertNotNil(PacingBadgeModel(state: .decisive(confidence: 0.3), enabled: true))
    }

    func testPacingBadgeTonesAndAdvice() {
        XCTAssertEqual(PacingBadgeModel(state: .decisive(confidence: 1), enabled: true)?.tone, .warning)
        XCTAssertEqual(PacingBadgeModel(state: .expansive(confidence: 1), enabled: true)?.tone, .success)
        XCTAssertEqual(PacingBadgeModel(state: .stalled(confidence: 1), enabled: true)?.advice, "Take the lead")
        XCTAssertEqual(PacingBadgeModel(state: .measured(confidence: 1), enabled: true)?.tone, .neutral)
    }

    // MARK: Answer clock

    func testAnswerClockTurnsAmberAtSixtyAndRedAtNinety() {
        let policy = AnswerClockPolicy()
        XCTAssertEqual(policy.tone(forElapsed: 30), .neutral)
        XCTAssertEqual(policy.tone(forElapsed: 60), .warning)
        XCTAssertEqual(policy.tone(forElapsed: 95), .critical)
        XCTAssertEqual(policy.progress(forElapsed: 45), 0.5, accuracy: 0.001)
        XCTAssertEqual(policy.progress(forElapsed: 400), 1)
        XCTAssertEqual(AnswerClockPolicy.label(forElapsed: 125.7), "2:05")
    }

    // MARK: Status bar hints

    func testStatusHintsChangeWithSurfaceAndScreen() {
        let assist = StatusHintCatalog.hints(surface: .assist, screen: .mentor)
        XCTAssertEqual(assist.first?.label, "Generate")
        XCTAssertEqual(assist.last?.label, "Hide")
        let settings = StatusHintCatalog.hints(surface: .assist, screen: .settings)
        XCTAssertEqual(settings.map(\.label), ["Settings", "Hide"])
        XCTAssertEqual(StatusHintCatalog.hints(surface: .design, screen: .mentor).first?.label, "Design")
    }

    // MARK: Layout

    func testBreakpointsAndDrawerFit() {
        XCTAssertEqual(OverlayLayout.breakpoint(for: 400), .compact)
        XCTAssertEqual(OverlayLayout.breakpoint(for: 560), .regular)
        XCTAssertEqual(OverlayLayout.breakpoint(for: 900), .wide)
        XCTAssertFalse(OverlayLayout.drawerFits(in: 600))
        XCTAssertFalse(OverlayLayout.drawerFits(in: 899))
        XCTAssertTrue(OverlayLayout.drawerFits(in: 900))
        XCTAssertEqual(OverlayLayout.readingWidth(for: 300), 320)
        XCTAssertEqual(OverlayLayout.readingWidth(for: 2000), OverlayLayout.readingColumnMaximum)
    }

    // MARK: Shortcuts

    func testShortcutCatalogResolvesRegistryEntriesAndFallsBack() {
        XCTAssertEqual(ShortcutCatalog.toggleOverlay, "Cmd+D")
        XCTAssertEqual(ShortcutCatalog.shortcut(for: "does-not-exist", fallback: "Cmd+Z"), "Cmd+Z")
        XCTAssertEqual(ShortcutCatalog.jumpToSection(.problem), "Cmd+1")
        XCTAssertEqual(ShortcutCatalog.jumpToSection(.systemDesign), "Cmd+6")
        for surface in MentorSurface.allCases {
            XCTAssertFalse(surface.shortcut.isEmpty)
        }
    }

    func testSwitchableScreensCoverEveryNonMentorScreen() {
        XCTAssertEqual(Set(OverlayScreen.switchable), Set(OverlayScreen.allCases).subtracting([.mentor]))
    }
}
