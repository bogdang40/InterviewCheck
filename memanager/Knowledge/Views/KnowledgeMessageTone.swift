import Foundation

/// The store reports outcomes as plain sentences; this picks the banner
/// tone from the wording so failures read as failures.
enum KnowledgeMessageTone {
    static func tone(for message: String) -> OverlayTone {
        let lowered = message.lowercased()
        if lowered.hasPrefix("could not") || lowered.contains("failed") { return .critical }
        if lowered.contains("already exists") { return .warning }
        return .info
    }
}
