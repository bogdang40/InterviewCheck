import AppKit
import Carbon
import ApplicationServices

extension HotkeyManager {
    func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            NSLog("[HotkeyManager] Event tap was disabled, re-enabling...")
            eventTap.enable()
            return nil
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let snapshot = bindingsSnapshot()
        // Check for hotkey matches
        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["toggleVisibility"]) {
            NSLog("[HotkeyManager] Toggle visibility triggered")
            dispatch(onToggleVisibility)
            return nil // Consume the event
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["startSession"]) {
            NSLog("[HotkeyManager] Start session triggered")
            DebugNDJSONLogger.shared.log(
                runId: "hotkey",
                hypothesisId: "H-HK",
                location: "HotkeyManager.handleEvent",
                message: "start_session_triggered",
                data: ["isAutoRepeat": isAutoRepeat]
            )
            if !isAutoRepeat {
                dispatch(onStartSession)
            }
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["screenshot"]) {
            dispatch(onScreenshot)
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["solve"]) {
            dispatch(onSolve)
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["resetSession"]) {
            dispatch(onResetSession)
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["openTranscriptLog"]) {
            dispatch(onOpenTranscriptLog)
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["togglePause"]) {
            if !isAutoRepeat {
                dispatch(onTogglePauseSession)
            }
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["endSession"]) {
            dispatch(onEndSession)
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["nextSection"]) {
            dispatch(onNextSection)
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["prevSection"]) {
            dispatch(onPrevSection)
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["openSettings"]) {
            dispatch(onOpenSettings)
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["quit"]) {
            dispatch(onQuit)
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["scrollDown"]) {
            NSLog("[HotkeyManager] Scroll down hotkey matched")
            dispatch(onScrollDown)
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["scrollUp"]) {
            NSLog("[HotkeyManager] Scroll up hotkey matched")
            dispatch(onScrollUp)
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["increaseWidth"]) {
            dispatch(onIncreaseWidth)
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["decreaseWidth"]) {
            dispatch(onDecreaseWidth)
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["anchorLeft"]) {
            dispatch(onAnchorLeft)
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["anchorRight"]) {
            dispatch(onAnchorRight)
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["nextStep"]) {
            dispatch(onNextStep)
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["prevStep"]) {
            dispatch(onPrevStep)
            return nil
        }

        if let commandOptionArrowAction = Self.commandOptionArrowAction(
            keyCode: keyCode,
            flags: flags,
            nextDesignHotkey: snapshot["nextDesignStep"],
            prevDesignHotkey: snapshot["prevDesignStep"],
            quickAssistHistoryEnabled: Self.quickAssistHistoryHotkeysEnabled(
                gate: shouldConsumeQuickAssistHistoryHotkeys
            ),
            systemDesignActive: isSystemDesignSurfaceActive?() ?? false
        ) {
            switch commandOptionArrowAction {
            case .nextDesignStep:
                dispatch(onNextDesignStep)
            case .prevDesignStep:
                dispatch(onPrevDesignStep)
            case .nextQuickAssistResponse:
                dispatch(onNextQuickAssistResponse)
            case .prevQuickAssistResponse:
                dispatch(onPrevQuickAssistResponse)
            }
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["quickAssistDeep"]) {
            NSLog("[HotkeyManager] Quick Assist Deep triggered")
            if !isAutoRepeat {
                dispatch(onQuickAssistDeep)
            }
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["quickAssist"]) {
            if !isAutoRepeat {
                dispatch(onQuickAssist)
            }
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["markCurrentSpeaker"]) {
            dispatch(onMarkCurrentSpeakerAsMe)
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["toggleSpeakerIdMode"]) {
            dispatch(onToggleSpeakerIdMode)
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["toggleDiagnostics"]) {
            dispatch(onToggleDiagnostics)
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["toggleTeleprompter"]) {
            guard Self.teleprompterHotkeysEnabled(gate: shouldConsumeTeleprompterHotkeys) else {
                return Unmanaged.passUnretained(event)
            }
            dispatch(onToggleTeleprompter)
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["nextChunk"]) {
            guard Self.teleprompterHotkeysEnabled(gate: shouldConsumeTeleprompterHotkeys) else {
                return Unmanaged.passUnretained(event)
            }
            dispatch(onNextChunk)
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["prevChunk"]) {
            guard Self.teleprompterHotkeysEnabled(gate: shouldConsumeTeleprompterHotkeys) else {
                return Unmanaged.passUnretained(event)
            }
            dispatch(onPrevChunk)
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["solveSystemDesign"]) {
            NSLog("[HotkeyManager] Solve System Design triggered")
            SessionLogger.shared.logNavigationEvent(
                name: "hotkey_systemDesign",
                details: "Cmd+Shift+Y pressed, isAutoRepeat=\(isAutoRepeat)"
            )
            if !isAutoRepeat {
                dispatch(onSolveSystemDesign)
            }
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["cancelRequest"]) {
            NSLog("[HotkeyManager] Cancel Request triggered")
            if !isAutoRepeat {
                dispatch(onCancelRequest)
            }
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["cycleProvider"]) {
            NSLog("[HotkeyManager] Cycle Provider triggered")
            if !isAutoRepeat {
                dispatch(onCycleProvider)
            }
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["quickAssistFollowUp"]) {
            NSLog("[HotkeyManager] Quick Assist Follow-up triggered")
            if !isAutoRepeat {
                dispatch(onQuickAssistFollowUp)
            }
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["quickAssistAutoSideQuestion"]) {
            NSLog("[HotkeyManager] Quick Assist Auto Side Question triggered")
            if !isAutoRepeat {
                dispatch(onQuickAssistAutoSideQuestion)
            }
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["quickAssistFocusQuestion"]) {
            if !isAutoRepeat {
                dispatch(onFocusQuickAssistQuestion)
            }
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["quickAssistCycleMode"]) {
            SessionLogger.shared.logDebugEvent(
                category: "hotkey",
                name: "quick_assist_cycle_mode_key_received",
                details: "keyCode=\(keyCode), flags=\(flags.rawValue), isAutoRepeat=\(isAutoRepeat)"
            )
            guard Self.quickAssistModeHotkeysEnabled(gate: shouldConsumeQuickAssistModeHotkeys) else {
                return Unmanaged.passUnretained(event)
            }
            if !isAutoRepeat {
                dispatch(onCycleQuickAssistMode)
            }
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["quickAssistFocusHistorySearch"]) {
            if !isAutoRepeat {
                dispatch(onFocusQuickAssistHistorySearch)
            }
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["cycleLiveResponseCard"]) {
            if !isAutoRepeat {
                dispatch(onCycleLiveResponseCard)
            }
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["pinLiveResponseCard"]) {
            if !isAutoRepeat {
                dispatch(onPinLiveResponseCard)
            }
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["quickAssistHistoryNextThread"]) {
            guard Self.quickAssistHistoryHotkeysEnabled(gate: shouldConsumeQuickAssistHistoryHotkeys) else {
                return Unmanaged.passUnretained(event)
            }
            if !isAutoRepeat {
                dispatch(onNextQuickAssistHistoryThread)
            }
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["quickAssistHistoryPrevThread"]) {
            guard Self.quickAssistHistoryHotkeysEnabled(gate: shouldConsumeQuickAssistHistoryHotkeys) else {
                return Unmanaged.passUnretained(event)
            }
            if !isAutoRepeat {
                dispatch(onPrevQuickAssistHistoryThread)
            }
            return nil
        }

        if Self.matchesHotkey(keyCode: keyCode, flags: flags, hotkey: snapshot["quickAssistHistoryOpenThread"]) {
            guard Self.quickAssistHistoryHotkeysEnabled(gate: shouldConsumeQuickAssistHistoryHotkeys) else {
                return Unmanaged.passUnretained(event)
            }
            if !isAutoRepeat {
                dispatch(onOpenQuickAssistHistoryThread)
            }
            return nil
        }

        if let quickAssistContextMode = Self.quickAssistContextMode(
            keyCode: keyCode,
            flags: flags,
            allSectionsHotkey: snapshot["quickAssistImplementationContext"],
            systemDesignHotkey: snapshot["quickAssistSystemDesignContext"]
        ) {
            switch quickAssistContextMode {
            case .allSectionsContext:
                NSLog("[HotkeyManager] Quick Assist All Sections Context triggered")
                if !isAutoRepeat {
                    dispatch(onQuickAssistImplementationContext)
                }
            case .implementationContext:
                NSLog("[HotkeyManager] Quick Assist Implementation Context triggered")
                if !isAutoRepeat {
                    dispatch(onQuickAssistImplementationContext)
                }
            case .systemDesignContext:
                NSLog("[HotkeyManager] Quick Assist System Design Context triggered")
                if !isAutoRepeat {
                    dispatch(onQuickAssistSystemDesignContext)
                }
            case .conversation:
                break
            }
            return nil
        }

        // Section jump hotkeys: strictly Cmd+1 through Cmd+6.
        if let section = Self.sectionIndexForCommandOnlyKey(keyCode: keyCode, flags: flags) {
            let sectionNames = ["problem", "approach", "implementation", "complexity", "tests", "systemDesign"]
            let sectionName = section < sectionNames.count ? sectionNames[section] : "unknown"
            SessionLogger.shared.logNavigationEvent(
                name: "hotkey_jumpToSection",
                to: sectionName,
                details: "Cmd+\(section + 1) pressed, sectionIndex=\(section)"
            )
            dispatch(onJumpToSection, section)
            return nil
        }

        if Self.isCommandOnlyShortcut(flags) {
            // Cmd+7 shows Quick Assist view (without regenerating)
            if keyCode == 26 { // 7
                SessionLogger.shared.logNavigationEvent(
                    name: "hotkey_showQuickAssist",
                    details: "Cmd+7 pressed"
                )
                dispatch(onShowQuickAssistView)
                return nil
            }
        }

        if shouldRouteOverlayKeyboardInput?() == true,
           let overlayCommand = Self.overlayCommand(
                keyCode: keyCode,
                flags: flags,
                event: event
           ),
           performOverlayCommand(overlayCommand) {
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

}
