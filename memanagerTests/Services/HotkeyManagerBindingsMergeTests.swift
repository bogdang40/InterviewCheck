import XCTest
@testable import memanager

final class HotkeyManagerBindingsMergeTests: XCTestCase {
    func testHotkeyCodingPreservesLegacyNumericModifiersAndUnknownBits() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for raw: UInt64 in [0, 1048576, 1179648, UInt64.max] {
            // Literal fixtures use the format written by the former
            // CGEventFlags RawRepresentable Codable conformance.
            let legacy = Data("{\"customAction\":{\"keyCode\":2,\"modifiers\":\(raw)}}".utf8)
            let decoded = try JSONDecoder().decode([String: HotkeyManager.Hotkey].self, from: legacy)
            XCTAssertEqual(decoded["customAction"]?.keyCode, 2)
            XCTAssertEqual(decoded["customAction"]?.modifiers.rawValue, raw)
            XCTAssertEqual(try encoder.encode(decoded), legacy)
        }
    }

    func testMergedBindingsInjectsDesignStepHotkeysAndPreservesSavedCustomizations() {
        let defaults: [String: HotkeyManager.Hotkey] = [
            "nextStep": .nextStep,
            "prevStep": .prevStep,
            "nextDesignStep": .nextDesignStep,
            "prevDesignStep": .prevDesignStep
        ]
        let saved: [String: HotkeyManager.Hotkey] = [
            "nextStep": HotkeyManager.Hotkey(keyCode: 45, modifiers: .maskCommand),
            "prevStep": HotkeyManager.Hotkey(keyCode: 46, modifiers: [.maskCommand, .maskShift]),
            "legacyAction": HotkeyManager.Hotkey(keyCode: 12, modifiers: [.maskCommand, .maskControl])
        ]

        let merged = HotkeyManager.mergedBindings(defaults: defaults, saved: saved)

        XCTAssertEqual(merged["nextStep"], saved["nextStep"])
        XCTAssertEqual(merged["prevStep"], saved["prevStep"])
        XCTAssertEqual(merged["nextDesignStep"], defaults["nextDesignStep"])
        XCTAssertEqual(merged["prevDesignStep"], defaults["prevDesignStep"])
        XCTAssertEqual(merged["legacyAction"], saved["legacyAction"])
    }

    func testScrollDefaultsUseShiftedCommandArrows() {
        XCTAssertEqual(
            HotkeyManager.Hotkey.scrollDown,
            HotkeyManager.Hotkey(keyCode: 124, modifiers: [.maskCommand, .maskShift])
        )
        XCTAssertEqual(
            HotkeyManager.Hotkey.scrollUp,
            HotkeyManager.Hotkey(keyCode: 123, modifiers: [.maskCommand, .maskShift])
        )
    }

    func testMigratedScrollBindingsRebindsLegacyDefaultsForOlderVersions() {
        let defaults: [String: HotkeyManager.Hotkey] = [
            "scrollDown": .scrollDown,
            "scrollUp": .scrollUp
        ]
        let saved: [String: HotkeyManager.Hotkey] = [
            "scrollDown": .legacyScrollDown,
            "scrollUp": .legacyScrollUp
        ]
        let merged = HotkeyManager.mergedBindings(defaults: defaults, saved: saved)

        let migrated = HotkeyManager.migratedScrollBindingsIfNeeded(
            merged: merged,
            saved: saved,
            savedVersion: 18
        )

        XCTAssertEqual(migrated["scrollDown"], .scrollDown)
        XCTAssertEqual(migrated["scrollUp"], .scrollUp)
    }

    func testMigratedScrollBindingsPreservesCustomBindingsForOlderVersions() {
        let customScrollDown = HotkeyManager.Hotkey(keyCode: 125, modifiers: .maskCommand)
        let customScrollUp = HotkeyManager.Hotkey(keyCode: 126, modifiers: .maskCommand)
        let defaults: [String: HotkeyManager.Hotkey] = [
            "scrollDown": .scrollDown,
            "scrollUp": .scrollUp
        ]
        let saved: [String: HotkeyManager.Hotkey] = [
            "scrollDown": customScrollDown,
            "scrollUp": customScrollUp
        ]
        let merged = HotkeyManager.mergedBindings(defaults: defaults, saved: saved)

        let migrated = HotkeyManager.migratedScrollBindingsIfNeeded(
            merged: merged,
            saved: saved,
            savedVersion: 18
        )

        XCTAssertEqual(migrated["scrollDown"], customScrollDown)
        XCTAssertEqual(migrated["scrollUp"], customScrollUp)
    }

    func testMigratedScrollBindingsNoOpAtCurrentOrNewerVersion() {
        let defaults: [String: HotkeyManager.Hotkey] = [
            "scrollDown": .scrollDown,
            "scrollUp": .scrollUp
        ]
        let saved: [String: HotkeyManager.Hotkey] = [
            "scrollDown": .legacyScrollDown,
            "scrollUp": .legacyScrollUp
        ]
        let merged = HotkeyManager.mergedBindings(defaults: defaults, saved: saved)

        let migrated = HotkeyManager.migratedScrollBindingsIfNeeded(
            merged: merged,
            saved: saved,
            savedVersion: 19
        )

        XCTAssertEqual(migrated["scrollDown"], .legacyScrollDown)
        XCTAssertEqual(migrated["scrollUp"], .legacyScrollUp)
    }

    func testSectionJumpRequiresStrictCommandOnlyModifiers() {
        XCTAssertEqual(
            HotkeyManager.sectionIndexForCommandOnlyKey(keyCode: 18, flags: .maskCommand),
            0
        )
        XCTAssertNil(
            HotkeyManager.sectionIndexForCommandOnlyKey(
                keyCode: 18,
                flags: [.maskCommand, .maskAlternate]
            )
        )
        XCTAssertNil(
            HotkeyManager.sectionIndexForCommandOnlyKey(
                keyCode: 18,
                flags: [.maskCommand, .maskControl]
            )
        )
    }

    func testCmdOptionQuickAssistHotkeysRouteToContextModes() {
        let allSectionsMode = HotkeyManager.quickAssistContextMode(
            keyCode: HotkeyManager.Hotkey.quickAssistImplementationContext.keyCode,
            flags: HotkeyManager.Hotkey.quickAssistImplementationContext.modifiers,
            allSectionsHotkey: .quickAssistImplementationContext,
            systemDesignHotkey: .quickAssistSystemDesignContext
        )
        XCTAssertEqual(allSectionsMode, .allSectionsContext)

        let systemDesignMode = HotkeyManager.quickAssistContextMode(
            keyCode: HotkeyManager.Hotkey.quickAssistSystemDesignContext.keyCode,
            flags: HotkeyManager.Hotkey.quickAssistSystemDesignContext.modifiers,
            allSectionsHotkey: .quickAssistImplementationContext,
            systemDesignHotkey: .quickAssistSystemDesignContext
        )
        XCTAssertEqual(systemDesignMode, .systemDesignContext)
    }

    func testCmdOptionArrowsRouteToDesignStepsWhenQuickAssistHistoryDisabled() {
        let nextAction = HotkeyManager.commandOptionArrowAction(
            keyCode: HotkeyManager.Hotkey.nextDesignStep.keyCode,
            flags: HotkeyManager.Hotkey.nextDesignStep.modifiers,
            nextDesignHotkey: .nextDesignStep,
            prevDesignHotkey: .prevDesignStep,
            quickAssistHistoryEnabled: false
        )
        XCTAssertEqual(nextAction, .nextDesignStep)

        let prevAction = HotkeyManager.commandOptionArrowAction(
            keyCode: HotkeyManager.Hotkey.prevDesignStep.keyCode,
            flags: HotkeyManager.Hotkey.prevDesignStep.modifiers,
            nextDesignHotkey: .nextDesignStep,
            prevDesignHotkey: .prevDesignStep,
            quickAssistHistoryEnabled: false
        )
        XCTAssertEqual(prevAction, .prevDesignStep)
    }

    func testActiveSystemDesignSurfaceWinsCmdOptionArrowsOverHistory() {
        // Previously Quick Assist history unconditionally won the shared
        // chords, silently disabling design step navigation whenever
        // history was enabled.
        let nextAction = HotkeyManager.commandOptionArrowAction(
            keyCode: HotkeyManager.Hotkey.nextDesignStep.keyCode,
            flags: HotkeyManager.Hotkey.nextDesignStep.modifiers,
            nextDesignHotkey: .nextDesignStep,
            prevDesignHotkey: .prevDesignStep,
            quickAssistHistoryEnabled: true,
            systemDesignActive: true
        )
        XCTAssertEqual(nextAction, .nextDesignStep)

        let prevAction = HotkeyManager.commandOptionArrowAction(
            keyCode: HotkeyManager.Hotkey.prevDesignStep.keyCode,
            flags: HotkeyManager.Hotkey.prevDesignStep.modifiers,
            nextDesignHotkey: .nextDesignStep,
            prevDesignHotkey: .prevDesignStep,
            quickAssistHistoryEnabled: true,
            systemDesignActive: true
        )
        XCTAssertEqual(prevAction, .prevDesignStep)
    }

    func testCmdOptionArrowsRouteToQuickAssistHistoryWhenEnabled() {
        let nextAction = HotkeyManager.commandOptionArrowAction(
            keyCode: HotkeyManager.Hotkey.nextDesignStep.keyCode,
            flags: HotkeyManager.Hotkey.nextDesignStep.modifiers,
            nextDesignHotkey: .nextDesignStep,
            prevDesignHotkey: .prevDesignStep,
            quickAssistHistoryEnabled: true
        )
        XCTAssertEqual(nextAction, .nextQuickAssistResponse)

        let prevAction = HotkeyManager.commandOptionArrowAction(
            keyCode: HotkeyManager.Hotkey.prevDesignStep.keyCode,
            flags: HotkeyManager.Hotkey.prevDesignStep.modifiers,
            nextDesignHotkey: .nextDesignStep,
            prevDesignHotkey: .prevDesignStep,
            quickAssistHistoryEnabled: true
        )
        XCTAssertEqual(prevAction, .prevQuickAssistResponse)
    }

    func testCmdOptionOneDoesNotRouteAsSectionJump() {
        let section = HotkeyManager.sectionIndexForCommandOnlyKey(
            keyCode: HotkeyManager.Hotkey.quickAssistImplementationContext.keyCode,
            flags: HotkeyManager.Hotkey.quickAssistImplementationContext.modifiers
        )
        XCTAssertNil(section)
    }

    func testTeleprompterHotkeyGateDefaultsToEnabledWhenUnset() {
        XCTAssertTrue(HotkeyManager.teleprompterHotkeysEnabled(gate: nil))
    }

    func testTeleprompterHotkeyGateRespectsQuickAssistState() {
        XCTAssertFalse(HotkeyManager.teleprompterHotkeysEnabled(gate: { false }))
        XCTAssertTrue(HotkeyManager.teleprompterHotkeysEnabled(gate: { true }))
    }

    func testQuickAssistHistoryHotkeyGateDefaultsToDisabledWhenUnset() {
        XCTAssertFalse(HotkeyManager.quickAssistHistoryHotkeysEnabled(gate: nil))
    }

    func testQuickAssistHistoryHotkeyGateRespectsControllerState() {
        XCTAssertFalse(HotkeyManager.quickAssistHistoryHotkeysEnabled(gate: { false }))
        XCTAssertTrue(HotkeyManager.quickAssistHistoryHotkeysEnabled(gate: { true }))
    }

    func testQuickAssistModeHotkeyGateDefaultsToDisabledWhenUnset() {
        XCTAssertFalse(HotkeyManager.quickAssistModeHotkeysEnabled(gate: nil))
    }

    func testQuickAssistModeHotkeyGateRespectsControllerState() {
        XCTAssertFalse(HotkeyManager.quickAssistModeHotkeysEnabled(gate: { false }))
        XCTAssertTrue(HotkeyManager.quickAssistModeHotkeysEnabled(gate: { true }))
    }

    func testQuickAssistAutoSideQuestionDefaultUsesCmdShiftSemicolon() {
        XCTAssertEqual(
            HotkeyManager.Hotkey.quickAssistAutoSideQuestion,
            HotkeyManager.Hotkey(keyCode: 41, modifiers: [.maskCommand, .maskShift])
        )
    }

    func testMergedBindingsInjectsQuickAssistAutoSideQuestionWhenMissingFromSavedData() {
        let defaults: [String: HotkeyManager.Hotkey] = [
            "quickAssistAutoSideQuestion": .quickAssistAutoSideQuestion
        ]
        let saved: [String: HotkeyManager.Hotkey] = [
            "quickAssist": .quickAssist
        ]

        let merged = HotkeyManager.mergedBindings(defaults: defaults, saved: saved)

        XCTAssertEqual(merged["quickAssistAutoSideQuestion"], .quickAssistAutoSideQuestion)
        XCTAssertEqual(merged["quickAssist"], .quickAssist)
    }

    func testQuickAssistFocusAndHistoryDefaultsAreRegistered() {
        XCTAssertEqual(
            HotkeyManager.Hotkey.quickAssistFocusQuestion,
            HotkeyManager.Hotkey(keyCode: 37, modifiers: .maskCommand)
        )
        XCTAssertEqual(
            HotkeyManager.Hotkey.quickAssistCycleMode,
            HotkeyManager.Hotkey(keyCode: 29, modifiers: .maskCommand)
        )
        XCTAssertEqual(
            HotkeyManager.Hotkey.quickAssistFocusHistorySearch,
            HotkeyManager.Hotkey(keyCode: 37, modifiers: [.maskCommand, .maskShift])
        )
        XCTAssertEqual(
            HotkeyManager.Hotkey.quickAssistHistoryNextThread,
            HotkeyManager.Hotkey(keyCode: 125, modifiers: [.maskCommand, .maskAlternate])
        )
        XCTAssertEqual(
            HotkeyManager.Hotkey.quickAssistHistoryPrevThread,
            HotkeyManager.Hotkey(keyCode: 126, modifiers: [.maskCommand, .maskAlternate])
        )
        XCTAssertEqual(
            HotkeyManager.Hotkey.quickAssistHistoryOpenThread,
            HotkeyManager.Hotkey(keyCode: 36, modifiers: [.maskCommand, .maskAlternate])
        )
    }

    func testMergedBindingsInjectsQuickAssistFocusAndHistoryShortcutsWhenMissing() {
        let defaults: [String: HotkeyManager.Hotkey] = [
            "quickAssistFocusQuestion": .quickAssistFocusQuestion,
            "quickAssistCycleMode": .quickAssistCycleMode,
            "quickAssistFocusHistorySearch": .quickAssistFocusHistorySearch,
            "quickAssistHistoryNextThread": .quickAssistHistoryNextThread,
            "quickAssistHistoryPrevThread": .quickAssistHistoryPrevThread,
            "quickAssistHistoryOpenThread": .quickAssistHistoryOpenThread
        ]
        let saved: [String: HotkeyManager.Hotkey] = [
            "quickAssist": .quickAssist
        ]

        let merged = HotkeyManager.mergedBindings(defaults: defaults, saved: saved)

        XCTAssertEqual(merged["quickAssistFocusQuestion"], .quickAssistFocusQuestion)
        XCTAssertEqual(merged["quickAssistCycleMode"], .quickAssistCycleMode)
        XCTAssertEqual(merged["quickAssistFocusHistorySearch"], .quickAssistFocusHistorySearch)
        XCTAssertEqual(merged["quickAssistHistoryNextThread"], .quickAssistHistoryNextThread)
        XCTAssertEqual(merged["quickAssistHistoryPrevThread"], .quickAssistHistoryPrevThread)
        XCTAssertEqual(merged["quickAssistHistoryOpenThread"], .quickAssistHistoryOpenThread)
        XCTAssertEqual(merged["quickAssist"], .quickAssist)
    }
}
