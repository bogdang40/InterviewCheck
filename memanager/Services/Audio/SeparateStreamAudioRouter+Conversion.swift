import AVFoundation
import CoreMedia
import Foundation

extension SeparateStreamAudioRouter {

    /// Convert system CMSampleBuffer to PCM16 Data
    func convertSystemToPCM16(_ sampleBuffer: CMSampleBuffer) -> (Data, SystemAudioBufferMetrics)? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            onSystemAudioConversionFailure?("missing_format_description")
            return nil
        }

        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0 else { return nil }

        // Create source format from sample buffer
        let sourceFormat: AVAudioFormat
        do {
            sourceFormat = try AVAudioFormat(cmAudioFormatDescription: formatDescription)
        } catch {
            logDebug("Failed to create audio format: \(error.localizedDescription)")
            onSystemAudioConversionFailure?("format_init_failed")
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
            onSystemAudioConversionFailure?("pcm_copy_failed_\(status)")
            return nil
        }

        return convertSystemBufferToPCM16(sourceBuffer, sourceFormat: sourceFormat)
    }

    func convertSystemBufferToPCM16(
        _ sourceBuffer: AVAudioPCMBuffer,
        sourceFormat: AVAudioFormat
    ) -> (Data, SystemAudioBufferMetrics)? {
        guard sourceBuffer.frameLength > 0 else { return nil }

        var conversionSteps: [String] = []
        conversionSteps.append(
            "src_\(Int(sourceFormat.sampleRate))hz_\(sourceFormat.channelCount)ch_\(sourceFormat.commonFormat == .pcmFormatFloat32 ? "f32" : "other")_\(sourceFormat.isInterleaved ? "interleaved" : "planar")"
        )

        guard let normalizedBuffer = normalizeToFloat32(sourceBuffer) else {
            onSystemAudioConversionFailure?("normalize_float32_failed")
            return nil
        }

        if normalizedBuffer.format.commonFormat != sourceFormat.commonFormat || sourceFormat.isInterleaved {
            conversionSteps.append("normalize_float32")
        }

        guard let monoBuffer = downmixToMono(normalizedBuffer) else {
            onSystemAudioConversionFailure?("downmix_failed")
            return nil
        }

        if normalizedBuffer.format.channelCount > 1 {
            conversionSteps.append("downmix_\(normalizedBuffer.format.channelCount)_to_1")
        }

        let processBuffer: AVAudioPCMBuffer
        if monoBuffer.format.sampleRate == targetFormat.sampleRate {
            processBuffer = monoBuffer
        } else {
            if lastSystemFormat != monoBuffer.format {
                lock.lock()
                lastSystemFormat = monoBuffer.format
                systemConverter = createConverterIfNeeded(from: monoBuffer.format)
                lock.unlock()
            }
            guard let converted = resampleBuffer(monoBuffer, from: monoBuffer.format, using: &systemConverter) else {
                onSystemAudioConversionFailure?("resample_failed")
                return nil
            }
            processBuffer = converted
            conversionSteps.append("resample_\(Int(monoBuffer.format.sampleRate))_to_\(Int(targetFormat.sampleRate))")
        }

        // Convert float32 to PCM16
        guard let pcm16Data = AudioSampleConverter.convertToInt16Data(processBuffer) else {
            onSystemAudioConversionFailure?("pcm16_encode_failed")
            return nil
        }

        let metrics = SystemAudioBufferMetrics(
            sourceSampleRate: sourceFormat.sampleRate,
            sourceChannels: sourceFormat.channelCount,
            frameLength: processBuffer.frameLength,
            rmsDb: calculateRMSdB(processBuffer),
            conversionPath: conversionSteps.joined(separator: " -> ")
        )

        return (pcm16Data, metrics)
    }

    #if DEBUG
    func testConvertSystemBufferToPCM16(_ buffer: AVAudioPCMBuffer) -> (Data, SystemAudioBufferMetrics)? {
        convertSystemBufferToPCM16(buffer, sourceFormat: buffer.format)
    }
    #endif

    func normalizeToFloat32(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let sourceFormat = buffer.format
        if sourceFormat.commonFormat == .pcmFormatFloat32 && !sourceFormat.isInterleaved {
            return buffer
        }

        guard let normalizedFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: sourceFormat.channelCount,
            interleaved: false
        ) else {
            return nil
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: normalizedFormat) else {
            return nil
        }

        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength))
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: normalizedFormat,
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
                return buffer
            }
            outStatus.pointee = .endOfStream
            return nil
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        if error != nil {
            return nil
        }
        return outputBuffer
    }

    func downmixToMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        guard format.commonFormat == .pcmFormatFloat32 else { return nil }

        if format.channelCount == 1 {
            return buffer
        }

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }

        guard let monoBuffer = AVAudioPCMBuffer(
            pcmFormat: monoFormat,
            frameCapacity: buffer.frameCapacity
        ) else {
            return nil
        }

        monoBuffer.frameLength = buffer.frameLength

        guard let sourceChannels = buffer.floatChannelData,
              let monoChannel = monoBuffer.floatChannelData?[0] else {
            return nil
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        let scale = 1.0 / Float(channelCount)

        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += sourceChannels[channel][frame]
            }
            monoChannel[frame] = sum * scale
        }

        return monoBuffer
    }

    // MARK: - Format Conversion Helpers

    /// Create converter from source format to target format
    func createConverterIfNeeded(from sourceFormat: AVAudioFormat) -> AVAudioConverter? {
        return AVAudioConverter(from: sourceFormat, to: targetFormat)
    }

    /// Resample buffer to target format
    func resampleBuffer(
        _ sourceBuffer: AVAudioPCMBuffer,
        from sourceFormat: AVAudioFormat,
        using converter: inout AVAudioConverter?
    ) -> AVAudioPCMBuffer? {
        // Ensure converter exists
        if converter == nil {
            converter = createConverterIfNeeded(from: sourceFormat)
        }

        guard let conv = converter else {
            logDebug("Failed to create converter")
            return nil
        }
        conv.reset()

        // Calculate output frame count with deterministic rounding and minimal headroom.
        // The headroom avoids edge truncation when converter internals round differently.
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let expectedFrameCount = Int((Double(sourceBuffer.frameLength) * ratio).rounded(.toNearestOrAwayFromZero))
        let outputFrameCount = AVAudioFrameCount(max(1, expectedFrameCount + 1))

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
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
                outStatus.pointee = .endOfStream
                return nil
            }
        }

        conv.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            logDebug("Resample error: \(error)")
            return nil
        }

        if outputBuffer.frameLength == 0 {
            consecutiveEmptyResampleCount += 1
            if consecutiveEmptyResampleCount >= 20, !didLogRepeatedEmptyResample {
                didLogRepeatedEmptyResample = true
                logDebug("Resample produced empty output repeatedly (count=\(consecutiveEmptyResampleCount), sourceRate=\(sourceFormat.sampleRate))")
            }
            return nil
        }

        consecutiveEmptyResampleCount = 0

        return outputBuffer
    }

    func calculateRMSdB(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let floatData = buffer.floatChannelData else { return -160.0 }
        let samples = floatData[0]
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return -160.0 }

        var sumSquares: Double = 0
        for i in 0..<frameLength {
            let sample = Double(samples[i])
            sumSquares += sample * sample
        }

        let rms = sqrt(sumSquares / Double(frameLength))
        guard rms > 0 else { return -160.0 }
        return 20.0 * log10(rms)
    }
}
