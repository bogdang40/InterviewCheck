import AppKit

enum HotkeyScope: String, CaseIterable {
    case global
    case overlayLocal
    case contextLocal
}

enum HotkeyOwnerSurface: String, CaseIterable {
    case overlayShell = "Overlay Shell"
    case session = "Session"
    case quickAssist = "Quick Assist"
    case history = "History"
    case teleprompter = "Teleprompter"
    case diagnostics = "Diagnostics"
    case transcript = "Transcript"
    case systemDesign = "System Design"
}

enum HotkeyConflictPolicy: String, CaseIterable {
    case exclusive
    case contextSwitched
    case disabledOutsideTarget
}

enum HotkeyInventorySection: String, CaseIterable {
    case session = "Session"
    case quickAssist = "Quick Assist"
    case navigation = "Navigation"
    case overlay = "Overlay"
    case overlayKeyboard = "Overlay Keyboard"
}

struct HotkeyRegistryEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let shortcut: String
    let scope: HotkeyScope
    let owner: HotkeyOwnerSurface
    let conflictPolicy: HotkeyConflictPolicy
    let section: HotkeyInventorySection
    let persistedBindingKey: String?
    let binding: HotkeyManager.Hotkey?
}

enum HotkeyRegistry {
    static let entries = sessionEntries + quickAssistEntries + navigationEntries + overlayEntries + overlayKeyboardEntries

    static let persistedEntries: [HotkeyRegistryEntry] = entries.filter { $0.persistedBindingKey != nil }

    static let settingsEntries: [HotkeyRegistryEntry] = entries

    static var defaultBindings: [String: HotkeyManager.Hotkey] {
        Dictionary(
            uniqueKeysWithValues: persistedEntries.compactMap { entry in
                guard let persistedBindingKey = entry.persistedBindingKey,
                      let binding = entry.binding else {
                    return nil
                }
                return (persistedBindingKey, binding)
            }
        )
    }

    static func duplicateBindings(in entries: [HotkeyRegistryEntry] = HotkeyRegistry.entries) -> [(HotkeyRegistryEntry, HotkeyRegistryEntry)] {
        var seen: [HotkeyManager.Hotkey: HotkeyRegistryEntry] = [:]
        var duplicates: [(HotkeyRegistryEntry, HotkeyRegistryEntry)] = []

        for entry in entries {
            guard let binding = entry.binding else { continue }
            if let existing = seen[binding] {
                duplicates.append((existing, entry))
            } else {
                seen[binding] = entry
            }
        }

        return duplicates
    }

    static func entries(for section: HotkeyInventorySection) -> [HotkeyRegistryEntry] {
        settingsEntries.filter { $0.section == section }
    }
}
