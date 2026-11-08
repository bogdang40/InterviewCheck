import Foundation
import AppKit

enum PermissionType: String, CaseIterable, Identifiable {
    case accessibility
    case microphone
    case speechRecognition
    case screenRecording

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .screenRecording: return "Screen Recording"
        }
    }

    var description: String {
        switch self {
        case .accessibility:
            return "Required for global hotkeys to work anywhere on your Mac"
        case .microphone:
            return "Required to capture audio for transcription"
        case .speechRecognition:
            return "Required to convert speech to text"
        case .screenRecording:
            return "Required to capture screenshots and system audio (Zoom, Teams, etc.)"
        }
    }

    var systemSettingsURL: URL? {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .speechRecognition:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }

    var icon: String {
        switch self {
        case .accessibility: return "hand.raised"
        case .microphone: return "mic"
        case .speechRecognition: return "waveform"
        case .screenRecording: return "rectangle.dashed.badge.record"
        }
    }
}

// MARK: - Permission Status

enum PermissionStatus: Equatable {
    case granted
    case denied
    case notDetermined
    case restricted

    var isGranted: Bool { self == .granted }

    var color: NSColor {
        switch self {
        case .granted: return .systemGreen
        case .denied: return .systemRed
        case .notDetermined: return .systemYellow
        case .restricted: return .systemOrange
        }
    }

    var displayText: String {
        switch self {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .notDetermined: return "Not Determined"
        case .restricted: return "Restricted"
        }
    }
}

