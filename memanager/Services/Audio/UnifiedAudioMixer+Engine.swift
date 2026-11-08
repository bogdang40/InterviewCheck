import AVFoundation
import AudioToolbox
import CoreMedia
import Combine
import os.log

extension UnifiedAudioMixer {
    func startInternal(allowRetry: Bool) throws {
        print("[MIC-DEBUG] UnifiedAudioMixer.start() called")
        guard !isActive else {
            logDebug("Already active, skipping start")
            return
        }

        // Always remove any lingering taps/scheduled audio from prior attempts.
        // This matters even when `isActive == false` (e.g., start failed after installing a tap).
        removeMixerTapIfNeeded()
        removeMicTapIfNeeded()
        systemAudioPlayerNode.stop()

        // Detach nodes from any prior engine before creating a fresh one.
        if hasAttachedNodes {
            audioEngine.stop()
            audioEngine.detach(mixerNode)
            audioEngine.detach(micGainNode)
            audioEngine.detach(isolationMixer)  // PHASE 6
            audioEngine.detach(systemAudioPlayerNode)
            audioEngine.detach(keepAliveNode)
            hasAttachedNodes = false
        }

        // Reset auto-balance state for a clean start.
        autoMicMultiplier = 1.0
        autoSystemMultiplier = 1.0
        micRmsPostGain = 0.0
        systemRmsPostGain = 0.0
        lastMicLevelTime = 0
        lastSystemLevelTime = 0
        lastAutoBalanceTime = 0
        // CRITICAL FIX: Create fresh engine instead of reset()
        // reset() invalidates input format; fresh engine has valid format immediately
        audioEngine = AVAudioEngine()
        mixerTapInstalled = false

        // Observe engine configuration changes (device routing changes mid-session).
        // The observer re-attaches per fresh engine; the previous token is
        // removed first, so restarts never accumulate live observers.
        engineConfigurationObserver.attach(to: audioEngine) { [weak self] in
            self?.handleEngineConfigurationChange()
        }

        // Attach nodes to fresh engine
        audioEngine.attach(mixerNode)
        audioEngine.attach(micGainNode)
        audioEngine.attach(isolationMixer)  // PHASE 6: Format isolation from hardware
        audioEngine.attach(systemAudioPlayerNode)
        audioEngine.attach(keepAliveNode)
        hasAttachedNodes = true

        // Log which audio device we're using for debugging
        AudioDeviceManager.logCurrentDevices()

        // Log transport types for smart device selection debugging
        if let inputID = AudioDeviceManager.resolvedInputDeviceID(),
           let outputID = AudioDeviceManager.resolvedOutputDeviceID() {
            let inputTransport = AudioDeviceManager.transportType(for: inputID)
            let outputTransport = AudioDeviceManager.transportType(for: outputID)
            logDebug("Input transport: \(inputTransport), Output transport: \(outputTransport)")

            if AudioDeviceManager.isBluetooth(outputID) && AudioDeviceManager.isBluetooth(inputID) {
                logDebug("Smart selection: Matched Bluetooth input to Bluetooth output")
            } else if AudioDeviceManager.isBluetooth(outputID) && !AudioDeviceManager.isBluetooth(inputID) {
                logDebug("Warning: Output is Bluetooth but input is not - check device availability")
            }
        }

        // Use smart device selection - matches input transport to output
        // This improves reliability on AirPods and other Bluetooth devices
        logDebug("Using smart input device selection")

        // NOTE: Do NOT call audioEngine.prepare() here - it throws uncatchable
        // NSException if hardware is in transient state. Format query works
        // without it; engine.start() handles initialization internally.

        // Get input format from microphone
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            throw UnifiedAudioMixerError.invalidInputFormat(
                sampleRate: inputFormat.sampleRate,
                channels: inputFormat.channelCount
            )
        }

        logDebug("Input device format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")
        logDebug("Mixer output format: \(mixerOutputFormat.sampleRate)Hz, \(mixerOutputFormat.channelCount)ch")

        // #region agent log
        let inputID = AudioDeviceManager.resolvedInputDeviceID()
        let outputID = AudioDeviceManager.resolvedOutputDeviceID()
        let inputName = inputID.flatMap { AudioDeviceManager.deviceName(for: $0) } ?? "nil"
        let outputName = outputID.flatMap { AudioDeviceManager.deviceName(for: $0) } ?? "nil"
        DebugNDJSONLogger.shared.log(
            runId: ndjsonRunId,
            hypothesisId: "H3",
            location: "UnifiedAudioMixer.startInternal",
            message: "unified_mixer_config",
            data: [
                "inputSampleRate": inputFormat.sampleRate,
                "inputChannels": Int(inputFormat.channelCount),
                "mixerTargetSampleRate": mixerOutputFormat.sampleRate,
                "mixerTargetChannels": Int(mixerOutputFormat.channelCount),
                "resolvedInputDeviceId": inputID.map { Int($0) } ?? -1,
                "resolvedInputDeviceName": inputName,
                "resolvedOutputDeviceId": outputID.map { Int($0) } ?? -1,
                "resolvedOutputDeviceName": outputName
            ]
        )
        // #endregion

        // PHASE 5 FIX: Configure maxFramesPerSlice for Bluetooth compatibility
        // Bluetooth HFP uses 513 frames per callback, but default max is 512.
        // Setting to 4096 accommodates all device types including Bluetooth.
        // Note: Only input/output nodes expose audioUnit; mixer nodes operate in software
        // and inherit buffer handling from the graph.
        if let inputAudioUnit = inputNode.audioUnit {
            configureMaxFramesPerSlice(inputAudioUnit)
        }
        if let outputAudioUnit = audioEngine.outputNode.audioUnit {
            configureMaxFramesPerSlice(outputAudioUnit)
        }
        logDebug("Configured audio units for Bluetooth compatibility (maxFramesPerSlice: 4096)")

        // Connect: microphone -> mic gain -> mixer
        // PHASE 10: Use format: nil on ALL mic path connections
        // The format parameter DECLARES what the source produces - it does NOT request conversion
        // Lying about format (saying 48kHz when source is 16kHz) creates undefined state
        // The downstream mixer->isolationMixer (48kHz) tells mixer what output to produce
        audioEngine.connect(inputNode, to: micGainNode, format: nil)  // Accept hardware format
        audioEngine.connect(micGainNode, to: mixerNode, format: nil)  // Accept whatever micGainNode outputs

        // Connect: system audio player -> mixer (explicit format since we control scheduled buffer format)
        audioEngine.connect(systemAudioPlayerNode, to: mixerNode, format: mixerOutputFormat)
        // Keep-alive node -> mixer (silent loop to keep Bluetooth SCO route active)
        audioEngine.connect(keepAliveNode, to: mixerNode, format: mixerOutputFormat)

        // PHASE 6: Use isolation mixer to decouple format requirements from hardware
        // mixerNode outputs our target format (48kHz mono) - this is where our tap lives
        // isolationMixer handles conversion to whatever mainMixerNode/hardware needs
        audioEngine.connect(mixerNode, to: isolationMixer, format: mixerOutputFormat)
        audioEngine.connect(isolationMixer, to: audioEngine.mainMixerNode, format: nil)

        // Mute main output - we only want the tap, not playback through speakers
        audioEngine.mainMixerNode.outputVolume = 0

        applyGains()

        // Track mic level for auto-balance (tap on mic gain output)
        // Use format: nil to accept whatever format the engine produces
        // PHASE 10: Add diagnostic to verify mic data flows even if mixer tap fails
        micGainNode.installTap(
            onBus: 0,
            bufferSize: Config.bufferSize,
            format: nil
        ) { [weak self] buffer, _ in
            // Diagnostic: verify mic tap fires (log every ~2 seconds)
            os_log("MicGainTap: %{public}d frames at %{public}.0fHz",
                   log: Self.audioLogger, type: .debug,
                   buffer.frameLength, buffer.format.sampleRate)

            self?.processingQueue.async {
                self?.processMicLevelBuffer(buffer)
            }
        }
        micTapInstalled = true

        // Install tap on mixer node BEFORE starting engine
        // PHASE 10: Use format: nil to accept whatever mixer produces
        // The downstream mixer->isolationMixer (48kHz) tells mixer what output to produce
        // ensureTargetFormat handles any remaining conversion to 48kHz mono
        mixerNode.installTap(
            onBus: 0,
            bufferSize: Config.bufferSize,
            format: nil  // Accept whatever mixer produces, convert in callback
        ) { [weak self] buffer, _ in
            // IMMEDIATE logging before async dispatch - verify tap is firing
            os_log("MixerTap: %{public}d frames at %{public}.0fHz",
                   log: Self.audioLogger, type: .debug,
                   buffer.frameLength, buffer.format.sampleRate)

            self?.processingQueue.async {
                guard let self = self else { return }
                // Convert to 48kHz mono if needed - skip buffer if conversion fails
                guard let outputBuffer = self.ensureTargetFormat(buffer) else {
                    self.conversionErrorCount += 1
                    if self.conversionErrorCount % 100 == 1 {
                        self.logDebug("Skipping buffer due to conversion error (count: \(self.conversionErrorCount))")
                    }
                    return
                }
                self.processMixedBuffer(outputBuffer)
            }
        }
        mixerTapInstalled = true

        // Prime output rendering before engine start to avoid output stream disabling.
        // A silent loop keeps the output path active even when no system audio is scheduled yet.
        systemAudioPlayerNode.play()
        startKeepAliveIfNeeded(force: true)

        // Prepare and start
        audioEngine.prepare()
        print("[MIC-DEBUG] About to call audioEngine.start()")
        do {
            try audioEngine.start()
            print("[MIC-DEBUG] audioEngine.start() succeeded!")

            // CRITICAL: Verify engine actually started (Bluetooth HFP state machine can cause false success)
            guard audioEngine.isRunning else {
                print("[MIC-DEBUG] CRITICAL: start() succeeded but isRunning is false - Bluetooth state conflict")
                lastError = "Audio engine failed to start (Bluetooth state conflict)"
                os_log("CRITICAL: audioEngine.start() succeeded but isRunning is false", log: Self.audioLogger, type: .error)
                removeMixerTapIfNeeded()
                removeMicTapIfNeeded()
                audioEngine.stop()
                throw UnifiedAudioMixerError.noInputDevice
            }
            print("[MIC-DEBUG] audioEngine.isRunning confirmed true")
        } catch {
            if allowRetry, AudioSampleConverter.isAudioUnitInitializationError(error) {
                logDebug("Audio engine init failed (-10875); retrying once")
                removeMixerTapIfNeeded()
                removeMicTapIfNeeded()
                audioEngine.stop()
                Thread.sleep(forTimeInterval: 0.15)
                return try startInternal(allowRetry: false)
            }
            throw error
        }

        // Player node already primed before start; keepAlive loop already scheduled.

        // PHASE 10: Log actual negotiated formats after engine starts
        // This reveals what formats the audio graph actually settled on
        let actualMixerFormat = mixerNode.outputFormat(forBus: 0)
        let actualInputFormat = inputNode.outputFormat(forBus: 0)
        os_log("Engine started - input: %{public}.0fHz %{public}dch, mixer output: %{public}.0fHz %{public}dch",
               log: Self.audioLogger, type: .info,
               actualInputFormat.sampleRate, actualInputFormat.channelCount,
               actualMixerFormat.sampleRate, actualMixerFormat.channelCount)

        // #region agent log
        DebugNDJSONLogger.shared.log(
            runId: ndjsonRunId,
            hypothesisId: "H3",
            location: "UnifiedAudioMixer.startInternal",
            message: "unified_mixer_started",
            data: [
                "engineIsRunning": audioEngine.isRunning,
                "actualInputSampleRate": actualInputFormat.sampleRate,
                "actualInputChannels": Int(actualInputFormat.channelCount),
                "actualMixerSampleRate": actualMixerFormat.sampleRate,
                "actualMixerChannels": Int(actualMixerFormat.channelCount)
            ]
        )
        // #endregion

        isActive = true
        lastError = nil
        logDebug("Started - \(Int(Config.sampleRate))Hz mono output")
    }
}
