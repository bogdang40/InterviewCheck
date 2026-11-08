import Foundation

/// Thread safe read only access to the active Mode's prompt, without touching the `@MainActor`
/// isolated `ModeStore`. Uses `UserDefaults` directly so callers from any queue can invoke it.
///
/// Writes go through `ModeStore` from the main actor; this bridge never writes.
enum ModeStoreBridge {
    private static let modesKey = "memanager.modes"
    private static let activeModeIDKey = "memanager.activeModeID"

    /// Returns the active Mode's prompt text if a mode is selected and the payload decodes.
    /// Nil otherwise. Callers fall back to the legacy QuickAssistPrompt path when nil.
    static func activePromptTextIfAvailable(defaults: UserDefaults = AppDefaults.standard) -> String? {
        guard let mode = activeMode(defaults: defaults) else { return nil }
        return mode.prompt
    }

    /// Returns the entire active Mode (prompt + attachments + project folder config).
    /// Used by mode injection and tool harness callers.
    static func activeMode(defaults: UserDefaults = AppDefaults.standard) -> Mode? {
        let modes = decodedModes(defaults: defaults)
        guard !modes.isEmpty else { return nil }
        if let raw = defaults.string(forKey: activeModeIDKey),
           let uuid = UUID(uuidString: raw),
           let match = modes.first(where: { $0.id == uuid }) {
            return match
        }
        return modes.first
    }

    static func mode(id: UUID, defaults: UserDefaults = AppDefaults.standard) -> Mode? {
        decodedModes(defaults: defaults).first(where: { $0.id == id })
    }

    private static func decodedModes(defaults: UserDefaults) -> [Mode] {
        guard let data = defaults.data(forKey: modesKey) else { return [] }
        return (try? JSONDecoder().decode([Mode].self, from: data)) ?? []
    }
}
