import AVFoundation
import Foundation
import Speech

/// Formats every value the diagnostics panel prints, so the rows stay
/// declarative and the wording can be tested.
enum DiagnosticsValueFormatter {
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func bool(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    static func timestamp(_ date: Date?) -> String {
        guard let date else { return "n/a" }
        return timestampFormatter.string(from: date)
    }

    static func timeAgo(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "n/a" }
        return String(format: "%.1fs ago", now.timeIntervalSince(date))
    }

    static func buffer(count: Int, last: Date?, now: Date = Date()) -> String {
        "\(count), \(timeAgo(last, now: now))"
    }

    static func decimal(_ value: Double, places: Int = 2) -> String {
        String(format: "%.\(places)f", value)
    }

    static func gain(_ value: Double) -> String {
        String(format: "%.2fx", value)
    }

    static func authorization(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    static func speechAuthorization(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    static func accessKey(_ status: AccessKeyStatus) -> String {
        switch status {
        case .loading: return "loading"
        case .saving: return "saving"
        case .unavailable(let message): return "unavailable (\(message))"
        case .configured: return "configured"
        case .notConfigured: return "notConfigured"
        case .saveFailed(let message): return "saveFailed (\(message))"
        }
    }

    static func deepgram(_ state: DeepgramConnectionState) -> String {
        switch state {
        case .connected: return "connected"
        case .connecting: return "connecting"
        case .disconnected: return "disconnected"
        case .error(let message): return "error (\(message))"
        }
    }

    static func sessionState(_ state: Session.SessionState) -> String {
        switch state {
        case .idle: return "idle"
        case .listening: return "listening"
        case .paused: return "paused"
        }
    }
}
