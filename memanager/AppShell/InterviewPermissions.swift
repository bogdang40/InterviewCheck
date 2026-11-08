import AppKit
import AVFoundation
import CoreGraphics

/// Asks for what an interview needs, when the interviewer presses Start,
/// never at launch: the microphone (their questions) and the computer's
/// audio (the candidate on the call, via Screen & System Audio Recording).
@MainActor
final class InterviewPermissions: ObservableObject {
    static let shared = InterviewPermissions()

    enum Problem: String, Identifiable {
        case deepgramKey, microphone, callAudio
        var id: String { rawValue }

        /// The button that fixes it.
        var actionTitle: String { self == .deepgramKey ? "Open Settings" : "Open System Settings" }

        var title: String {
            switch self {
            case .deepgramKey: return "Add a Deepgram key"
            case .microphone: return "Allow the microphone"
            case .callAudio: return "Allow \(AppBrand.name) to hear the call"
            }
        }

        var message: String {
            switch self {
            case .deepgramKey:
                return "\(AppBrand.name) times every answer word by word, which needs Deepgram. Add the key in Settings \u{203A} Keys."
            case .microphone:
                return "Your questions are timed from your microphone. Turn on \(AppBrand.name) in System Settings \u{203A} Privacy & Security \u{203A} Microphone."
            case .callAudio:
                return "The candidate's answers come from your computer's audio. Turn on \(AppBrand.name) in System Settings \u{203A} Privacy & Security \u{203A} Screen & System Audio Recording, then quit and reopen \(AppBrand.name)."
            }
        }

        var settingsURL: URL {
            let pane = self == .microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        }
    }

    @Published var problem: Problem?

    /// Checks permissions, asking the first time, then starts the interview.
    func startInterview(_ controller: InterviewController = .shared) async {
        guard controller.canStart else {
            controller.start() // explains what is missing (the notice)
            return
        }
        guard VoiceSignatureStore.shared.hasDeepgramApiKey else {
            problem = .deepgramKey
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                problem = .microphone
                return
            }
        default:
            problem = .microphone
            return
        }
        if !CGPreflightScreenCaptureAccess() {
            // Shows the system prompt the first time; access takes effect
            // after the app is reopened.
            guard CGRequestScreenCaptureAccess() else {
                problem = .callAudio
                return
            }
        }
        controller.start()
    }

    func openSettings(for problem: Problem) {
        if problem == .deepgramKey {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSWorkspace.shared.open(problem.settingsURL)
        }
    }
}
