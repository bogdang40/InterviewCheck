import Foundation
import CoreGraphics

// MARK: - Transcription Error Types

enum TranscriptionError: LocalizedError, Equatable {
    case microphoneDenied
    case speechRecognitionDenied
    case speechRecognitionRestricted
    case recognizerUnavailable
    case recognizerNotSupported
    case audioEngineFailure(String)
    case noAudioInput
    case invalidAudioFormat
    case screenRecordingDenied
    case systemAudioDisabled
    case systemAudioCaptureFailed(String)
    case systemAudioSilent
    case systemStreamStalled
    case sourceBasedPipelineUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone Access Required"
        case .speechRecognitionDenied:
            return "Speech Recognition Access Denied"
        case .speechRecognitionRestricted:
            return "Speech Recognition Restricted"
        case .recognizerUnavailable:
            return "Speech Recognizer Unavailable"
        case .recognizerNotSupported:
            return "Speech Recognition Not Supported"
        case .audioEngineFailure(let details):
            return "Audio Capture Error: \(details)"
        case .noAudioInput:
            return "No Audio Input Available"
        case .invalidAudioFormat:
            return "Invalid Audio Format"
        case .screenRecordingDenied:
            return "Screen Recording Permission Required"
        case .systemAudioDisabled:
            return "System Audio Capture Disabled"
        case .systemAudioCaptureFailed(let details):
            return "System Audio Capture Error: \(details)"
        case .systemAudioSilent:
            return "System Audio Is Silent"
        case .systemStreamStalled:
            return "System Audio Stream Stalled"
        case .sourceBasedPipelineUnavailable(let details):
            return "Source-Based Transcription Unavailable: \(details)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .microphoneDenied:
            return "Enable in System Settings > Privacy & Security > Microphone"
        case .speechRecognitionDenied:
            return "Enable in System Settings > Privacy & Security > Speech Recognition"
        case .speechRecognitionRestricted:
            return "Speech recognition is restricted on this device"
        case .recognizerUnavailable:
            return "Check your internet connection or try again later"
        case .recognizerNotSupported:
            return "Speech recognition is not available for English (US)"
        case .audioEngineFailure:
            return "Try restarting the app or check audio settings"
        case .noAudioInput:
            return "Check microphone permissions and ensure a microphone is connected"
        case .invalidAudioFormat:
            return "Try restarting the app"
        case .screenRecordingDenied:
            return "System audio capture requires Screen Recording permission. Enable in System Settings > Privacy & Security > Screen Recording"
        case .systemAudioDisabled:
            return "Enable \"Capture system audio\" in Settings to record other participants"
        case .systemAudioCaptureFailed:
            return "Try restarting the app or re-enabling system audio capture"
        case .systemAudioSilent:
            return "Audio stream is active but silent. Verify call output device and app audio routing."
        case .systemStreamStalled:
            return "Audible system audio was detected but transcript updates stalled. Retry stream or re-check Screen Recording permission."
        case .sourceBasedPipelineUnavailable:
            return "Source-based mode is enabled but the system stream pipeline is unhealthy. Retry stream or switch mode in Settings."
        }
    }

    var systemSettingsURL: URL? {
        switch self {
        case .microphoneDenied:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .speechRecognitionDenied, .speechRecognitionRestricted:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        case .screenRecordingDenied:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .systemAudioDisabled, .systemAudioCaptureFailed, .systemAudioSilent, .systemStreamStalled, .sourceBasedPipelineUnavailable:
            return nil
        default:
            return nil
        }
    }

    static func == (lhs: TranscriptionError, rhs: TranscriptionError) -> Bool {
        return lhs.errorDescription == rhs.errorDescription
    }
}

struct SystemAudioHealthSnapshot {
    var rmsDb: Double = -160
    var lastBufferAt: Date?
    var lastTranscriptAt: Date?
    var systemTranscriptCount: Int = 0
    var conversionFailureCount: Int = 0
    var selectedDisplayID: CGDirectDisplayID?
}
