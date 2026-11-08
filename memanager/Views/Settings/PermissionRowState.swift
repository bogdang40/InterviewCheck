import Foundation

/// Pure mapping from a permission status to what the row shows.
enum PermissionRowState {
    static func dotState(for status: PermissionStatus) -> StatusDotState {
        switch status {
        case .granted: return .ready
        case .denied, .restricted: return .error
        case .notDetermined: return .idle
        }
    }

    static func badgeTone(for status: PermissionStatus) -> OverlayTone {
        switch status {
        case .granted: return .success
        case .denied, .restricted: return .critical
        case .notDetermined: return .warning
        }
    }

    /// Summary banner copy for the whole set.
    static func summary(missingCount: Int) -> (tone: OverlayTone, title: String, message: String) {
        if missingCount == 0 {
            return (.success, "All listed permissions granted", "Permission checks passed. Capture and provider connections are checked separately.")
        }
        let noun = missingCount == 1 ? "permission needs" : "permissions need"
        return (.warning, "Permissions needed", "\(missingCount) \(noun) attention before every feature works.")
    }
}
