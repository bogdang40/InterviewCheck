import AVFoundation
import AudioToolbox
import CoreMedia
import Combine
import os.log

extension UnifiedAudioMixer {
    // MARK: - CMSampleBuffer Conversion

    /// Convert CMSampleBuffer to AVAudioPCMBuffer in mixer format
    func convertToPCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }

        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0 else { return nil }

        // Create source format from sample buffer
        let sourceFormat: AVAudioFormat
        do {
            sourceFormat = try AVAudioFormat(cmAudioFormatDescription: formatDescription)
        } catch {
            logDebug("Failed to create audio format: \(error)")
            return nil
        }

        // Create source buffer
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(sampleCount)
        ) else {
            return nil
        }

        sourceBuffer.frameLength = AVAudioFrameCount(sampleCount)

        // Copy data from CMSampleBuffer
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(sampleCount),
            into: sourceBuffer.mutableAudioBufferList
        )

        guard status == noErr else {
            logDebug("Failed to copy PCM data: \(status)")
            return nil
        }

        // If format matches exactly (including interleaving), return directly
        if sourceFormat.sampleRate == mixerOutputFormat.sampleRate &&
           sourceFormat.channelCount == mixerOutputFormat.channelCount &&
           sourceFormat.commonFormat == .pcmFormatFloat32 &&
           sourceFormat.isInterleaved == mixerOutputFormat.isInterleaved {
            return sourceBuffer
        }

        // Sample rate/channels match but format differs (e.g. int16 or interleaved),
        // convert to mixer output format.
        if sourceFormat.sampleRate == mixerOutputFormat.sampleRate &&
           sourceFormat.channelCount == mixerOutputFormat.channelCount {
            return convertToFloat32(sourceBuffer)
        }

        // Need to resample/convert to mixer format
        return resampleBuffer(sourceBuffer, from: sourceFormat)
    }

    /// Convert int16 buffer to float32
    func convertToFloat32(_ sourceBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(
            from: sourceBuffer.format,
            to: mixerOutputFormat
        ) else {
            return nil
        }

        let frameCapacity = AVAudioFrameCount(
            Double(sourceBuffer.frameLength) *
            mixerOutputFormat.sampleRate / sourceBuffer.format.sampleRate
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: mixerOutputFormat,
            frameCapacity: frameCapacity
        ) else {
            return nil
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            logDebug("Conversion error: \(error)")
            return nil
        }

        return outputBuffer
    }

    /// Resample buffer to mixer output format
    func resampleBuffer(
        _ sourceBuffer: AVAudioPCMBuffer,
        from sourceFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        // Create or reuse converter
        if systemAudioConverter == nil ||
           systemAudioConverter?.inputFormat != sourceFormat {
            systemAudioConverter = AVAudioConverter(
                from: sourceFormat,
                to: mixerOutputFormat
            )
        }

        guard let converter = systemAudioConverter else {
            logDebug("Failed to create converter")
            return nil
        }

        // Calculate output frame count based on sample rate ratio
        let ratio = mixerOutputFormat.sampleRate / sourceFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: mixerOutputFormat,
            frameCapacity: outputFrameCount
        ) else {
            return nil
        }

        var error: NSError?
        var hasData = true

        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if hasData {
                hasData = false
                outStatus.pointee = .haveData
                return sourceBuffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            logDebug("Resample error: \(error)")
            return nil
        }

        return outputBuffer
    }

    // MARK: - Format Conversion for Tap Output

    /// Ensure buffer is in the target mixer output format (48kHz mono float32)
    /// Uses dedicated micConverter to avoid interference with system audio conversion
    /// Returns nil if conversion fails - caller should skip the buffer
    ///
    /// Handles Bluetooth HFP mode transitions where sample rate drops from 48kHz to 16kHz.
    /// Detects format changes, recreates converter, and triggers restart after threshold failures.
    func ensureTargetFormat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        let inputSampleRate = format.sampleRate

        // PHASE 7: Detect HFP format transition (48kHz -> 16kHz when AirPods switch to mic mode)
        if inputSampleRate != lastSeenInputSampleRate && lastSeenInputSampleRate > 0 {
            logDebug("HFP TRANSITION: Input sample rate changed \(lastSeenInputSampleRate)Hz -> \(inputSampleRate)Hz")
            // Release logging for visibility in production builds
            os_log("HFP TRANSITION: %{public}.0f -> %{public}.0fHz",
                   log: Self.audioLogger, type: .info,
                   lastSeenInputSampleRate, inputSampleRate)
            // Force converter recreation for new format
            micConverter = nil
            consecutiveConversionFailures = 0
        } else if lastSeenInputSampleRate == 0 {
            // First buffer - log initial format
            os_log("Initial audio format: %{public}.0fHz %{public}dch",
                   log: Self.audioLogger, type: .info,
                   inputSampleRate, format.channelCount)
        }
        lastSeenInputSampleRate = inputSampleRate

        // Fast path: already in target format
        if format.sampleRate == mixerOutputFormat.sampleRate &&
           format.channelCount == mixerOutputFormat.channelCount &&
           format.commonFormat == mixerOutputFormat.commonFormat {
            consecutiveConversionFailures = 0
            return buffer
        }

        // Create or reuse dedicated mic converter
        // Use explicit property comparison instead of format object equality
        if micConverter == nil ||
           micConverter?.inputFormat.sampleRate != format.sampleRate ||
           micConverter?.inputFormat.channelCount != format.channelCount {
            logDebug("Creating converter: \(format.sampleRate)Hz \(format.channelCount)ch -> 48kHz mono")
            micConverter = AVAudioConverter(from: format, to: mixerOutputFormat)
        }

        guard let converter = micConverter else {
            logDebug("ERROR: Failed to create mic converter")
            handleConversionFailure()
            return nil
        }

        // Calculate output frame count based on sample rate ratio
        let ratio = mixerOutputFormat.sampleRate / format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: mixerOutputFormat,
            frameCapacity: outputFrameCount
        ) else {
            logDebug("ERROR: Failed to create output buffer for mic conversion")
            handleConversionFailure()
            return nil
        }

        var error: NSError?
        var hasData = true

        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if hasData {
                hasData = false
                outStatus.pointee = .haveData
                return buffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            logDebug("ERROR: Conversion failed: \(error.localizedDescription)")
            handleConversionFailure()
            return nil
        }

        // Validate output has actual frames
        guard outputBuffer.frameLength > 0 else {
            logDebug("ERROR: Conversion produced empty buffer")
            handleConversionFailure()
            return nil
        }

        // Success - reset failure counter
        consecutiveConversionFailures = 0
        return outputBuffer
    }

    /// Handle conversion failures with threshold-based restart trigger
    /// After too many consecutive failures, triggers engine reconfiguration
    func handleConversionFailure() {
        consecutiveConversionFailures += 1

        if consecutiveConversionFailures >= conversionFailureThreshold {
            logDebug("RESTART TRIGGER: Too many conversion failures (\(consecutiveConversionFailures)), requesting engine restart")
            consecutiveConversionFailures = 0

            // Trigger engine reconfiguration on main thread
            DispatchQueue.main.async { [weak self] in
                self?.onConfigurationChange?()
            }
        }
    }
}
