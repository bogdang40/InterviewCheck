import SwiftUI

/// Every registered hotkey, grouped by inventory section, with the key
/// drawn as key caps so it is learned by shape rather than read as text.
struct HotkeySettingsView: View {
    @State private var query = ""
    @State private var selectedSection: HotkeyInventorySection?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            OverlaySearchField(placeholder: "Find an action or shortcut", text: $query)
            Picker("Show shortcuts", selection: $selectedSection) {
                Text("All sections").tag(nil as HotkeyInventorySection?)
                ForEach(HotkeyInventorySection.allCases, id: \.self) { section in
                    Text(section.rawValue).tag(Optional(section))
                }
            }
            .pickerStyle(.menu)
            Text("Shortcuts are fixed. Each action shows where its shortcut is available.")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)

            ForEach(HotkeyInventorySection.allCases, id: \.self) { section in
                let entries = HotkeySearch.entries(query: query, section: section, selection: selectedSection)
                if !entries.isEmpty {
                SettingsSection(section.rawValue) {
                    ForEach(entries) { entry in
                        HotkeyRow(entry: entry)
                    }
                }
                }
            }
            if HotkeyInventorySection.allCases.allSatisfy({ HotkeySearch.entries(query: query, section: $0, selection: selectedSection).isEmpty }) {
                OverlayEmptyState(systemImage: "keyboard", title: "No matching shortcuts", message: "Try another action name or clear the filters.", primary: EmptyStateAction(title: "Clear filters") {
                    query = ""
                    selectedSection = nil
                })
            }
        }
    }
}

/// One action and its key cap.
struct HotkeyRow: View {
    let entry: HotkeyRegistryEntry

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(entry.title)
                    .font(OverlayType.callout)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(HotkeySearch.scopeLabel(entry.scope))
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
            }
            Spacer(minLength: DesignTokens.Spacing.md)
            KeyCap(shortcut: entry.shortcut, emphasized: true)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(minHeight: 34)
        .help("\(entry.title): \(entry.shortcut)")
    }
}

enum HotkeySearch {
    static func entries(query: String, section: HotkeyInventorySection, selection: HotkeyInventorySection?) -> [HotkeyRegistryEntry] {
        guard selection == nil || selection == section else { return [] }
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return HotkeyRegistry.entries(for: section).filter { entry in
            search.isEmpty || [entry.title, entry.shortcut, scopeLabel(entry.scope)]
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    static func scopeLabel(_ scope: HotkeyScope) -> String {
        switch scope {
        case .global: return "Global"
        case .overlayLocal: return "While the overlay has keyboard focus"
        case .contextLocal: return "In the relevant view"
        }
    }
}
