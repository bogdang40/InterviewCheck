import Foundation

// MARK: - Audio Source

/// Identifies the audio capture source
enum AudioSource: String, Codable, Equatable {
    case microphone
    case systemAudio
}

// MARK: - Speaker Label

/// Speaker label derived from voice signature analysis
enum SpeakerLabel: String, Codable, Equatable {
    case me
    case other
    case unknown

    var displayName: String {
        switch self {
        case .me: return "You"
        case .other: return "Other"
        case .unknown: return "Unknown"
        }
    }
}

// MARK: - Score Sample

/// A single score sample with timestamp for alignment
struct SpeakerScoreSample {
    let timestamp: TimeInterval
    let score: Float
    let source: AudioSource
}

// MARK: - Voice Signature State

/// Overall state of voice signature feature
struct VoiceSignatureState: Equatable {
    var enabled: Bool
    var hasProfile: Bool
    var thresholdEnterMe: Float
    var thresholdExitMe: Float

    static var `default`: VoiceSignatureState {
        VoiceSignatureState(
            enabled: false,
            hasProfile: false,
            thresholdEnterMe: 0.85,
            thresholdExitMe: 0.75
        )
    }
}

// MARK: - Recognition Config

/// Configuration for speaker state machine
struct SpeakerRecognitionConfig: Equatable {
    var thresholdEnterMe: Float
    var thresholdExitMe: Float
    var smoothingFactor: Float  // EMA alpha
    var minFramesToEnter: Int   // Consecutive frames above threshold
    var minFramesToExit: Int    // Consecutive frames below threshold

    static var `default`: SpeakerRecognitionConfig {
        SpeakerRecognitionConfig(
            thresholdEnterMe: 0.85,
            thresholdExitMe: 0.75,
            smoothingFactor: 0.3,
            minFramesToEnter: 3,
            minFramesToExit: 5
        )
    }

    init(
        thresholdEnterMe: Float = 0.85,
        thresholdExitMe: Float = 0.75,
        smoothingFactor: Float = 0.3,
        minFramesToEnter: Int = 3,
        minFramesToExit: Int = 5
    ) {
        self.thresholdEnterMe = thresholdEnterMe
        self.thresholdExitMe = thresholdExitMe
        self.smoothingFactor = smoothingFactor
        self.minFramesToEnter = minFramesToEnter
        self.minFramesToExit = minFramesToExit
    }
}
