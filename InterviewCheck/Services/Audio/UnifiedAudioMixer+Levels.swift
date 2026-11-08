import AVFoundation
import AudioToolbox
import CoreMedia
import Combine
import os.log

extension UnifiedAudioMixer {
    // MARK: - Buffer Processing

    // Buffer counter for periodic release logging
    static var processedBufferCount: Int = 0

    func processMixedBuffer(_ buffer: AVAudioPCMBuffer) {
        // Signal mic activity - the mixer always includes mic input
        onMicBuffer?()

        let now = CFAbsoluteTimeGetCurrent()
        let rms = computeRms(buffer)
        if rms < 0.005 {
            mixedSilentStreak += 1
        } else {
            mixedSilentStreak = 0
        }
        if now - lastNDJSONMixedRmsLogTime >= 2.0 {
            lastNDJSONMixedRmsLogTime = now
            let inputID = AudioDeviceManager.resolvedInputDeviceID()
            let outputID = AudioDeviceManager.resolvedOutputDeviceID()
            let inputName = inputID.flatMap { AudioDeviceManager.deviceName(for: $0) } ?? "nil"
            let outputName = outputID.flatMap { AudioDeviceManager.deviceName(for: $0) } ?? "nil"
            // #region agent log
            DebugNDJSONLogger.shared.log(
                runId: ndjsonRunId,
                hypothesisId: "H5",
                location: "UnifiedAudioMixer.processMixedBuffer",
                message: "mixed_audio_rms",
                data: [
                    "rms": Double(rms),
                    "silentStreak": mixedSilentStreak,
                    "frameLength": Int(buffer.frameLength),
                    "sampleRate": buffer.format.sampleRate,
                    "channelCount": Int(buffer.format.channelCount),
                    "resolvedInputDeviceId": inputID.map { Int($0) } ?? -1,
                    "resolvedInputDeviceName": inputName,
                    "resolvedOutputDeviceId": outputID.map { Int($0) } ?? -1,
                    "resolvedOutputDeviceName": outputName
                ]
            )
            // #endregion
        }

        guard let data = AudioSampleConverter.convertToInt16Data(buffer) else { return }

        // Periodic release logging to confirm audio flow (every ~2 seconds at 48kHz/1024)
        Self.processedBufferCount += 1
        if Self.processedBufferCount % 100 == 0 {
            os_log("Audio flowing: %{public}d buffers processed, %{public}d bytes",
                   log: Self.audioLogger, type: .debug,
                   Self.processedBufferCount, data.count)
        }

        onMixedAudio?(data)
    }

    func processMicLevelBuffer(_ buffer: AVAudioPCMBuffer) {
        micRmsPostGain = computeRms(buffer)
        lastMicLevelTime = CFAbsoluteTimeGetCurrent()

        // DIAGNOSTIC: Log mic input RMS when audio is present
        if micRmsPostGain > 0.001 {
            logDebug("MIC INPUT RMS: \(String(format: "%.4f", micRmsPostGain)) (gain: \(String(format: "%.2f", effectiveMicGain())))")
        }

        maybeAutoBalance()
    }

    func noteSystemLevel(_ buffer: AVAudioPCMBuffer) {
        systemRmsPostGain = computeRms(buffer) * effectiveSystemGain()
        lastSystemLevelTime = CFAbsoluteTimeGetCurrent()
        maybeAutoBalance()
    }

    func maybeAutoBalance() {
        guard autoBalanceEnabled else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastAutoBalanceTime < Config.autoBalanceUpdateInterval { return }

        // Only balance when both sources have meaningful recent energy.
        if now - lastMicLevelTime > 1.0 { return }
        if now - lastSystemLevelTime > 1.0 { return }
        if micRmsPostGain < Config.autoBalanceMinActiveRms { return }
        if systemRmsPostGain < Config.autoBalanceMinActiveRms { return }

        let micDb = 20.0 * log10(max(micRmsPostGain, 1e-6))
        let sysDb = 20.0 * log10(max(systemRmsPostGain, 1e-6))
        let delta = micDb - sysDb

        let step = pow(10.0, Config.autoBalanceStepDb / 20.0)

        if delta > Config.autoBalanceThresholdDb {
            if autoSystemMultiplier < Config.autoBalanceMaxMultiplier {
                autoSystemMultiplier = min(Config.autoBalanceMaxMultiplier, autoSystemMultiplier * Float(step))
            } else {
                autoMicMultiplier = max(Config.autoBalanceMinMultiplier, autoMicMultiplier / Float(step))
            }
        } else if delta < -Config.autoBalanceThresholdDb {
            if autoMicMultiplier < Config.autoBalanceMaxMultiplier {
                autoMicMultiplier = min(Config.autoBalanceMaxMultiplier, autoMicMultiplier * Float(step))
            } else {
                autoSystemMultiplier = max(Config.autoBalanceMinMultiplier, autoSystemMultiplier / Float(step))
            }
        } else {
            // Gentle relaxation towards neutral when balanced.
            let relax: Float = 0.02
            autoMicMultiplier += (1.0 - autoMicMultiplier) * relax
            autoSystemMultiplier += (1.0 - autoSystemMultiplier) * relax
        }

        applyGains()
        lastAutoBalanceTime = now
    }

    func computeRms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let floatData = buffer.floatChannelData else { return 0.0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0.0 }

        let samples = floatData[0]  // First channel (mono)
        var sumSquares: Float = 0.0
        for i in 0..<frameLength {
            let sample = samples[i]
            sumSquares += sample * sample
        }
        return sqrt(sumSquares / Float(frameLength))
    }
}
