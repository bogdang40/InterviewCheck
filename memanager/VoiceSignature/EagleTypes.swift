import Foundation

// MARK: - Error Types

/// Errors from Eagle C API operations
enum EagleError: LocalizedError, Equatable {
    case invalidAccessKey
    case accessKeyActivationFailed
    case accessKeyThrottled
    case accessKeyActivationLimitReached
    case accessKeyActivationRefused
    case modelLoadFailed(String)
    case invalidState
    case outOfMemory
    case invalidArgument
    case stopIterationReached
    case audioTooShort
    case audioTooLong
    case audioNoVoice
    case audioQualityIssue
    case audioUnknownSpeaker
    case processingFailed(Int32)
    case exportFailed
    case runtimeError
    case sdkNotAvailable
    case unsupportedSDK(String)
    case missingSDKSymbol(String)
    case unknown(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidAccessKey:
            return "Invalid Picovoice AccessKey"
        case .accessKeyActivationFailed:
            return "AccessKey activation failed - check internet connection"
        case .accessKeyThrottled:
            return "AccessKey activation throttled - try again later"
        case .accessKeyActivationLimitReached:
            return "AccessKey activation limit reached"
        case .accessKeyActivationRefused:
            return "AccessKey activation refused"
        case .modelLoadFailed(let path):
            return "Failed to load Eagle model at: \(path)"
        case .invalidState:
            return "Eagle is in an invalid state"
        case .outOfMemory:
            return "Out of memory"
        case .invalidArgument:
            return "Invalid argument passed to Eagle"
        case .stopIterationReached:
            return "Stop iteration reached"
        case .audioTooShort:
            return "Audio too short for enrollment"
        case .audioTooLong:
            return "Audio too long"
        case .audioNoVoice:
            return "No voice detected in audio"
        case .audioQualityIssue:
            return "Audio quality issue - try reducing background noise"
        case .audioUnknownSpeaker:
            return "Unknown speaker detected - ensure only you are speaking"
        case .processingFailed(let code):
            return "Processing failed with code: \(code)"
        case .exportFailed:
            return "Failed to export voice profile"
        case .runtimeError:
            return "Eagle runtime error"
        case .sdkNotAvailable:
            return "Eagle SDK is not available - please download the SDK"
        case .unsupportedSDK(let version):
            return "Unsupported Eagle SDK version: \(version). Reinstall this build's bundled Eagle 3.0 SDK."
        case .missingSDKSymbol(let name):
            return "The Eagle SDK is missing a required function: \(name)."
        case .unknown(let code):
            return "Unknown Eagle error (code: \(code))"
        }
    }

    static func == (lhs: EagleError, rhs: EagleError) -> Bool {
        lhs.errorDescription == rhs.errorDescription
    }

    /// Convert C API status code to EagleError
    static func from(status: Int32) -> EagleError? {
        switch status {
        case 0: return nil // PV_STATUS_SUCCESS
        case 1: return .outOfMemory // PV_STATUS_OUT_OF_MEMORY
        case 2: return .modelLoadFailed("IO Error") // PV_STATUS_IO_ERROR
        case 3: return .invalidArgument // PV_STATUS_INVALID_ARGUMENT
        case 4: return .stopIterationReached // PV_STATUS_STOP_ITERATION
        case 5: return .invalidAccessKey // PV_STATUS_KEY_ERROR
        case 6: return .invalidState // PV_STATUS_INVALID_STATE
        case 7: return .runtimeError // PV_STATUS_RUNTIME_ERROR
        case 8: return .accessKeyActivationFailed // PV_STATUS_ACTIVATION_ERROR
        case 9: return .accessKeyActivationLimitReached // PV_STATUS_ACTIVATION_LIMIT_REACHED
        case 10: return .accessKeyThrottled // PV_STATUS_ACTIVATION_THROTTLED
        case 11: return .accessKeyActivationRefused // PV_STATUS_ACTIVATION_REFUSED
        default: return .unknown(status)
        }
    }
}

// MARK: - Enrollment Feedback

/// Feedback from Eagle during enrollment
enum EagleEnrollmentFeedback {
    case progressOnly
    case audioOK
    case audioTooShort
    case unknownSpeaker
    case noVoiceFound
    case qualityIssue

    /// Convert from C API feedback code
    static func from(code: Int32) -> EagleEnrollmentFeedback {
        switch code {
        case 0: return .audioOK // PV_EAGLE_PROFILER_ENROLL_FEEDBACK_AUDIO_OK
        case 1: return .audioTooShort // PV_EAGLE_PROFILER_ENROLL_FEEDBACK_AUDIO_TOO_SHORT
        case 2: return .unknownSpeaker // PV_EAGLE_PROFILER_ENROLL_FEEDBACK_UNKNOWN_SPEAKER
        case 3: return .noVoiceFound // PV_EAGLE_PROFILER_ENROLL_FEEDBACK_NO_VOICE_FOUND
        case 4: return .qualityIssue // PV_EAGLE_PROFILER_ENROLL_FEEDBACK_QUALITY_ISSUE
        default: return .qualityIssue
        }
    }
}

// MARK: - Protocols

/// Protocol for Eagle Profiler (enrollment)
protocol EagleProfilerProtocol {
    func enroll(pcm: [Int16]) throws -> (progress: Float, feedback: EagleEnrollmentFeedback)
    func exportProfile() throws -> Data
    func reset() throws
    func destroy()
}

/// Protocol for Eagle Engine (recognition)
protocol EagleEngineProtocol {
    var minimumAudioSamples: Int { get }
    func process(pcm: [Int16]) throws -> Float
    func reset() throws
    func destroy()
}

/// Protocol for Eagle bindings
protocol EagleBindingsProtocol {
    static var sampleRate: Int { get }
    static var frameLength: Int { get }
    static var minEnrollSamples: Int { get }

    static func createProfiler(accessKey: String, modelPath: String) throws -> EagleProfilerProtocol
    static func createEngine(accessKey: String, modelPath: String, profile: Data) throws -> EagleEngineProtocol
}


// Existing synthetic engines can retain their small test frames. Real engines
// query this requirement from the SDK instance before audio capture starts.
extension EagleEngineProtocol {
    var minimumAudioSamples: Int { 512 }
}
