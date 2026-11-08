import Foundation

/// One shot migration from the legacy `QuickAssistPrompt` storage to the new Mode store.
/// Safe to call on every launch: it short circuits if already migrated, and it leaves the old
/// UserDefaults keys in place so the legacy code path can still read them as a fallback.
enum ModeMigrator {
    private static let migrationVersionKey = "memanager.modes.migrationVersion"
    private static let legacyPromptsKey = "memanager.quickAssistPrompts"
    private static let legacyActiveIDKey = "memanager.quickAssistActivePromptID"
    private static let newModesKey = "memanager.modes"
    private static let newActiveIDKey = "memanager.activeModeID"
    private static let currentVersion = 1

    static func runIfNeeded(defaults: UserDefaults = AppDefaults.standard) {
        let existingVersion = defaults.integer(forKey: migrationVersionKey)
        if existingVersion >= currentVersion { return }

        migrateLegacyPrompts(defaults: defaults)
        migrateActiveID(defaults: defaults)
        defaults.set(currentVersion, forKey: migrationVersionKey)
        NSLog("[ModeMigrator] Migrated legacy Quick Assist prompts into Modes (v\(currentVersion)).")
    }

    private static func migrateLegacyPrompts(defaults: UserDefaults) {
        if defaults.data(forKey: newModesKey) != nil { return }
        guard let data = defaults.data(forKey: legacyPromptsKey) else { return }
        let prompts = (try? JSONDecoder().decode([QuickAssistPrompt].self, from: data)) ?? []
        let modes = prompts.map { Mode(legacy: $0) }
        if let encoded = try? JSONEncoder().encode(modes) {
            defaults.set(encoded, forKey: newModesKey)
        }
    }

    private static func migrateActiveID(defaults: UserDefaults) {
        if defaults.string(forKey: newActiveIDKey) != nil { return }
        if let raw = defaults.string(forKey: legacyActiveIDKey) {
            defaults.set(raw, forKey: newActiveIDKey)
        }
    }
}
