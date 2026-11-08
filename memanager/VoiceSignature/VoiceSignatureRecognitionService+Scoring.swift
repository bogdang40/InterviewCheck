import AVFoundation
import Combine
import Foundation

extension VoiceSignatureRecognitionService {
    func processFrame(_ frame: [Int16], timestamp: TimeInterval, source: AudioSource) {
        guard isProcessingActive() else { return }

        do {
            // Preserve score/state ordering across the two audio queues. Release
            // the engine lock before invoking callbacks that may stop recognition.
            let sample = try engineLock.withLock { () -> SpeakerScoreSample? in
                guard isProcessingActive(), let engine else { return nil }
                let score = try engine.process(pcm: frame)
                guard isProcessingActive() else { return nil }
                let sample = SpeakerScoreSample(timestamp: timestamp, score: score, source: source)
                appendToTimeline(sample)
                updateStateMachine(score: score)
                return sample
            }
            if let sample { onScoreSample?(sample) }

        } catch EagleError.audioNoVoice {
            // Eagle 3 can accept a chunk without enough voice to score it.
            // Preserve the existing speaker state until a real score arrives.
        } catch {
            let shouldReport = stateLock.withLock { () -> Bool in
                guard isActiveFlag, !hasReportedProcessingError else { return false }
                hasReportedProcessingError = true
                return true
            }
            guard shouldReport else { return }
            onProcessingError?(error)
            #if DEBUG
            print("[VoiceSignatureRecognition] Frame processing error: \(error)")
            #endif
        }
    }

    func updateStateMachine(score: Float) {
        stateLock.lock()

        // Apply EMA smoothing
        if hasInitializedEMA {
            emaScore = config.smoothingFactor * score + (1 - config.smoothingFactor) * emaScore
        } else {
            emaScore = score
            hasInitializedEMA = true
        }

        let localEmaScore = emaScore
        let localCurrentLabel = currentLabelState

        // Update consecutive counters
        if localEmaScore >= config.thresholdEnterMe {
            consecutiveAboveThreshold += 1
            consecutiveBelowThreshold = 0
        } else if localEmaScore < config.thresholdExitMe {
            consecutiveBelowThreshold += 1
            consecutiveAboveThreshold = 0
        } else {
            // In hysteresis band - maintain current state
        }

        let aboveCount = consecutiveAboveThreshold
        let belowCount = consecutiveBelowThreshold

        stateLock.unlock()

        // Determine new label
        var newLabel = localCurrentLabel

        switch localCurrentLabel {
        case .unknown, .other:
            // Transition to .me requires consecutive frames above enter threshold
            if aboveCount >= config.minFramesToEnter {
                newLabel = .me
            }
        case .me:
            // Transition away from .me requires consecutive frames below exit threshold
            if belowCount >= config.minFramesToExit {
                newLabel = .other
            }
        }

        stateLock.withLock { currentLabelState = newLabel }

        // Publish updates on main thread
        let finalLabel = newLabel
        let finalScore = score
        let finalEma = localEmaScore

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.currentScore = finalScore
            self.smoothedScore = finalEma

            if finalLabel != self.currentLabel {
                self.currentLabel = finalLabel
                self.onLabelChanged?(finalLabel)
            }
        }
    }

    func resetStateMachine() {
        stateLock.lock()
        defer { stateLock.unlock() }

        consecutiveAboveThreshold = 0
        consecutiveBelowThreshold = 0
        emaScore = 0.0
        hasInitializedEMA = false
        hasReportedProcessingError = false
    }

    func appendToTimeline(_ sample: SpeakerScoreSample) {
        timelineLock.lock()
        defer { timelineLock.unlock() }

        scoreTimeline.append(sample)

        // Trim if exceeds max length
        if scoreTimeline.count > maxTimelineLength {
            scoreTimeline.removeFirst(scoreTimeline.count - maxTimelineLength)
        }
    }

    func clearTimeline() {
        timelineLock.lock()
        defer { timelineLock.unlock() }
        scoreTimeline.removeAll(keepingCapacity: true)
    }

    func setActiveFlag(_ value: Bool) {
        stateLock.lock()
        isActiveFlag = value
        stateLock.unlock()
    }

    func isProcessingActive() -> Bool {
        stateLock.lock()
        let active = isActiveFlag
        stateLock.unlock()
        return active
    }

    func beginEnqueue(for source: AudioSource) -> Bool {
        queueDepthLock.lock()
        defer { queueDepthLock.unlock() }

        switch source {
        case .microphone:
            guard pendingMicBuffers < maxPendingBuffersPerSource else {
                droppedMicBuffers += 1
                return false
            }
            pendingMicBuffers += 1
            return true
        case .systemAudio:
            guard pendingSystemBuffers < maxPendingBuffersPerSource else {
                droppedSystemBuffers += 1
                return false
            }
            pendingSystemBuffers += 1
            return true
        }
    }

    func finishEnqueue(for source: AudioSource) {
        queueDepthLock.lock()
        defer { queueDepthLock.unlock() }

        switch source {
        case .microphone:
            pendingMicBuffers = max(0, pendingMicBuffers - 1)
        case .systemAudio:
            pendingSystemBuffers = max(0, pendingSystemBuffers - 1)
        }
    }
}
