import AppKit
import Carbon
import ApplicationServices

extension HotkeyManager {
    // Version tracking - increment when default bindings change
    private static let currentBindingsVersion = 23
    private static let scrollShiftRebindVersion = 19
    func updateBinding(action: String, hotkey: Hotkey) {
        let snapshot = bindingsLock.withLock {
            bindings[action] = hotkey
            return bindings
        }
        saveBindings(snapshot: snapshot)
    }

    private func saveBindings(snapshot: [String: Hotkey]) {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(snapshot) {
            AppDefaults.standard.set(data, forKey: "memanager.HotkeyBindings")
            AppDefaults.standard.set(Self.currentBindingsVersion, forKey: "memanager.HotkeyBindingsVersion")
        }
    }

    func loadBindings() {
        let savedVersion = AppDefaults.standard.integer(forKey: "memanager.HotkeyBindingsVersion")
        NSLog("[HotkeyManager] Loading bindings: savedVersion=\(savedVersion), currentVersion=\(Self.currentBindingsVersion)")
        let defaults = HotkeyRegistry.defaultBindings
        guard let data = AppDefaults.standard.data(forKey: "memanager.HotkeyBindings"),
              let saved = try? JSONDecoder().decode([String: Hotkey].self, from: data) else {
            NSLog("[HotkeyManager] No decodable saved bindings found. Writing defaults.")
            bindingsLock.withLock {
                bindings = defaults
            }
            saveBindings(snapshot: defaults)
            return
        }

        let merged = Self.mergedBindings(defaults: defaults, saved: saved)
        let migrated = Self.migratedScrollBindingsIfNeeded(
            merged: merged,
            saved: saved,
            savedVersion: savedVersion
        )
        bindingsLock.withLock {
            bindings = migrated
        }

        // Persist migrated bindings to inject new defaults while preserving user customizations.
        if savedVersion != Self.currentBindingsVersion || migrated != saved {
            saveBindings(snapshot: migrated)
        }
    }

    static func mergedBindings(defaults: [String: Hotkey], saved: [String: Hotkey]) -> [String: Hotkey] {
        var merged = defaults
        merged.merge(saved) { _, savedValue in savedValue }
        return merged
    }

    static func migratedScrollBindingsIfNeeded(
        merged: [String: Hotkey],
        saved: [String: Hotkey],
        savedVersion: Int
    ) -> [String: Hotkey] {
        guard savedVersion < Self.scrollShiftRebindVersion else {
            return merged
        }

        var migrated = merged
        if saved["scrollDown"] == .legacyScrollDown {
            migrated["scrollDown"] = .scrollDown
        }
        if saved["scrollUp"] == .legacyScrollUp {
            migrated["scrollUp"] = .scrollUp
        }
        return migrated
    }

    func bindingsSnapshot() -> [String: Hotkey] {
        bindingsLock.withLock { bindings }
    }

}
