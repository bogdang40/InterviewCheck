import Foundation
import CoreAudio

extension AudioCaptureService {
    // MARK: - Source-Based Mode Handling

    func handleSourceBasedToggle(_ enabled: Bool) {
        sourceBasedToggleTask?.cancel()
        sourceBasedToggleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if self.desiredState == .idle {
                self.logDebug("Source-based mode toggled while idle: \(enabled)")
                return
            }

            switch self.captureState {
            case .recording, .starting:
                self.logDebug("Source-based mode toggled during recording; restarting capture")
                self.requestPause()
                let paused = await self.waitForCaptureState(.paused, timeout: 6.0)
                guard paused else {
                    self.logDebug("Source-based toggle: pause timed out; leaving state unchanged")
                    return
                }
                self.requestStart(reason: .resume)
            case .paused, .pausing, .stopping, .idle:
                self.logDebug("Source-based mode toggled; will apply on next start (state=\(self.captureState.displayName))")
            }
        }
    }

    func startMonitoringInputDevices() {
        guard !isMonitoringInputDevices else { return }
        isMonitoringInputDevices = true
        lastResolvedInputDeviceID = AudioDeviceManager.resolvedInputDeviceID()
        lastResolvedOutputDeviceID = AudioDeviceManager.resolvedOutputDeviceID()

        AudioDeviceManager.startMonitoringInputChanges { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.handleInputDeviceChange()
            }
        }
    }

    @MainActor
    private func handleInputDeviceChange() {
        let resolvedInputID = AudioDeviceManager.resolvedInputDeviceID()
        let resolvedOutputID = AudioDeviceManager.resolvedOutputDeviceID()
        let inputChanged = resolvedInputID != lastResolvedInputDeviceID
        let outputChanged = resolvedOutputID != lastResolvedOutputDeviceID

        // SMART SELECTION: Check if Bluetooth state changed
        // If output switched to/from Bluetooth, our smart input selection may change
        let outputWasBluetooth = lastResolvedOutputDeviceID.map { AudioDeviceManager.isBluetooth($0) } ?? false
        let outputIsBluetooth = resolvedOutputID.map { AudioDeviceManager.isBluetooth($0) } ?? false
        let bluetoothStateChanged = outputWasBluetooth != outputIsBluetooth

        if !inputChanged && !outputChanged && !bluetoothStateChanged {
            return
        }

        // Update tracked values
        if outputChanged || bluetoothStateChanged {
            lastResolvedOutputDeviceID = resolvedOutputID
        }

        // Re-evaluate smart selection when Bluetooth state changes
        let newSmartInputID = AudioDeviceManager.smartInputDeviceID()
        let smartInputChanged = newSmartInputID != lastResolvedInputDeviceID

        if inputChanged || smartInputChanged {
            lastResolvedInputDeviceID = newSmartInputID
        }

        guard captureState == .recording else { return }

        // Reconfigure if input changed, output changed, or Bluetooth state changed
        if inputChanged || outputChanged || bluetoothStateChanged || smartInputChanged {
            // #region agent log
            let inputName = newSmartInputID.flatMap { AudioDeviceManager.deviceName(for: $0) } ?? "nil"
            let outputName = resolvedOutputID.flatMap { AudioDeviceManager.deviceName(for: $0) } ?? "nil"
            let inputTransport = newSmartInputID.map { AudioDeviceManager.transportType(for: $0).description } ?? "nil"
            let outputTransport = resolvedOutputID.map { AudioDeviceManager.transportType(for: $0).description } ?? "nil"
            DebugNDJSONLogger.shared.log(
                runId: ndjsonRunId,
                hypothesisId: "H3",
                location: "AudioCaptureService.handleInputDeviceChange",
                message: "device_change_detected",
                data: [
                    "captureState": captureState.displayName,
                    "mode": activeTranscriptionMode.displayName,
                    "inputChanged": inputChanged,
                    "outputChanged": outputChanged,
                    "bluetoothStateChanged": bluetoothStateChanged,
                    "smartInputChanged": smartInputChanged,
                    "newInputDeviceId": newSmartInputID.map { Int($0) } ?? -1,
                    "newInputDeviceName": inputName,
                    "newInputTransport": inputTransport,
                    "newOutputDeviceId": resolvedOutputID.map { Int($0) } ?? -1,
                    "newOutputDeviceName": outputName
                    ,"newOutputTransport": outputTransport
                ]
            )
            // #endregion

            logDebug("Device change detected: input=\(inputChanged), output=\(outputChanged), bluetooth=\(bluetoothStateChanged), smartInput=\(smartInputChanged)")
            scheduleInputDeviceReconfigure()
        }
    }

    /// Handle audio engine configuration changes (device routing changes mid-session)
    /// MODIFIED: Made passive - proactive restart caused restart storms during Bluetooth transitions
    /// Now relying on buffer timeout detection for recovery instead
    @MainActor
    func handleEngineConfigurationChange() {
        guard captureState == .recording else { return }
        logDebug("Engine configuration changed - relying on buffer timeout for recovery if needed")
        // DISABLED: scheduleInputDeviceReconfigure() caused restart storms
        // The 200ms delay was too short for Bluetooth HFP transitions (need 2-5 seconds)
        // Buffer timeout detection will handle recovery after hardware stabilizes
    }

    @MainActor
    private func scheduleInputDeviceReconfigure() {
        inputDeviceChangeTask?.cancel()
        inputDeviceChangeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            await self?.reconfigureForInputDeviceChange()
        }
    }

    @MainActor
    private func reconfigureForInputDeviceChange() async {
        guard captureState == .recording else { return }
        guard !isReconfiguringInputDevice else { return }
        isReconfiguringInputDevice = true
        defer { isReconfiguringInputDevice = false }

        var outcome = "unknown"
        var outcomeError: String?
        var requestedStop = false

        switch activeTranscriptionMode {
        case .deepgramLegacy:
            do {
                try unifiedAudioMixer?.restartForDeviceChange()
                logDebug("Unified mixer reconfigured for input device change")
                outcome = "legacy_restart_success"
            } catch let error as UnifiedAudioMixerError {
                logDebug("Unified mixer reconfigure failed: \(error)")
                outcome = "legacy_restart_failed"
                outcomeError = String(describing: error)
                switch error {
                case .noInputDevice:
                    setError(.noAudioInput)
                case .invalidInputFormat:
                    setError(.invalidAudioFormat)
                }
            } catch {
                logDebug("Unified mixer reconfigure failed: \(error)")
                outcome = "legacy_restart_failed"
                outcomeError = error.localizedDescription
                setError(.audioEngineFailure("Unified mixer: \(error.localizedDescription)"))
            }
        case .deepgramSourceBased:
            await restartSystemStream(reason: "route_change")
            outcome = "source_based_system_restart"
        case .appleAnalyzer:
            await restartSystemStream(reason: "route_change")
            outcome = "apple_analyzer_system_restart"
        case .appleSpeech:
            let restarted = await restartMicEngineForDeviceChange()
            if restarted {
                logDebug("Audio engine reconfigured for input device change")
                outcome = "mic_restart_success"
            } else {
                logDebug("Audio engine reconfigure failed; stopping capture")
                outcome = "mic_restart_failed"
                requestedStop = true
                desiredState = .idle
                scheduleStateMachine()
            }
        }

        // #region agent log
        DebugNDJSONLogger.shared.log(
            runId: ndjsonRunId,
            hypothesisId: "H3",
            location: "AudioCaptureService.reconfigureForInputDeviceChange",
            message: "device_reconfigure_result",
            data: [
                "mode": activeTranscriptionMode.displayName,
                "outcome": outcome,
                "requestedStop": requestedStop,
                "error": outcomeError ?? ""
            ]
        )
        // #endregion
    }
}
