import Foundation

/// Semantic tone for an HTTP method chip: reads are calm, creates are
/// informational, updates warn, deletes are critical.
enum DesignAPIMethodTone {
    static func tone(for method: String) -> OverlayTone {
        switch method.uppercased() {
        case "GET", "HEAD", "OPTIONS": return .success
        case "POST": return .info
        case "PUT", "PATCH": return .warning
        case "DELETE": return .critical
        default: return .neutral
        }
    }
}
