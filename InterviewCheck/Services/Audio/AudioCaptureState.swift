import AVFoundation
import Combine
import Speech
import AppKit
import CoreMedia
import CoreAudio

extension AudioCaptureService {
    enum CaptureState {
        case idle
        case starting
        case recording
        case pausing
        case paused
        case stopping
    }

    enum DesiredCaptureState {
        case idle
        case recording
        case paused
    }

    enum StartPhase {
        case idle
        case checkingPermissions
        case startingEngine
        case started
        case failed
    }

    enum TranscriptionMode {
        case appleSpeech
        case appleAnalyzer
        case deepgramLegacy
        case deepgramSourceBased

        var usesDeepgram: Bool {
            self == .deepgramLegacy || self == .deepgramSourceBased
        }

        var usesLegacyDeepgram: Bool {
            self == .deepgramLegacy
        }

        var usesSourceBasedDeepgram: Bool {
            self == .deepgramSourceBased
        }

        var usesAppleAnalyzer: Bool {
            self == .appleAnalyzer
        }

        /// Modes that require the system audio stream to hear the other party
        /// force-enable ScreenCaptureKit capture regardless of the setting.
        var forcesSystemAudioCapture: Bool {
            self != .appleSpeech
        }

        /// Dual stream modes share the source based topology: mic = "me",
        /// system audio = other party, merged by TranscriptMerger.
        var usesDualStreamTopology: Bool {
            self == .deepgramSourceBased || self == .appleAnalyzer
        }
    }

    enum StartReason: Equatable {
        case newSession
        case resume
        case restoredSession

        func canStart(from state: CaptureState, hasRestoredTranscript: Bool) -> Bool {
            switch self {
            case .newSession: return true
            case .resume: return state == .paused
            case .restoredSession: return state == .idle && hasRestoredTranscript
            }
        }
    }
}
extension AudioCaptureService.CaptureState {
    var displayName: String {
        switch self {
        case .idle: return "idle"
        case .starting: return "starting"
        case .recording: return "recording"
        case .pausing: return "pausing"
        case .paused: return "paused"
        case .stopping: return "stopping"
        }
    }
}

extension AudioCaptureService.DesiredCaptureState {
    var displayName: String {
        switch self {
        case .idle: return "idle"
        case .recording: return "recording"
        case .paused: return "paused"
        }
    }
}

extension AudioCaptureService.StartPhase {
    var displayName: String {
        switch self {
        case .idle: return "idle"
        case .checkingPermissions: return "checkingPermissions"
        case .startingEngine: return "startingEngine"
        case .started: return "started"
        case .failed: return "failed"
        }
    }
}

extension AudioCaptureService.TranscriptionMode {
    var displayName: String {
        switch self {
        case .appleSpeech: return "Apple Speech"
        case .appleAnalyzer: return "Apple Analyzer (on-device)"
        case .deepgramLegacy: return "Deepgram (legacy)"
        case .deepgramSourceBased: return "Deepgram (source-based)"
        }
    }
}

extension AudioCaptureService.StartReason {
    var displayName: String {
        switch self {
        case .newSession: return "newSession"
        case .resume: return "resume"
        case .restoredSession: return "restoredSession"
        }
    }
}
