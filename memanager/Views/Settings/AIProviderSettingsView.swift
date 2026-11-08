import SwiftUI

/// The Providers pane: which provider answers, one section per provider
/// with its key, models, and connection tests, and the coding language.
struct AIProviderSettingsView: View {
    @ObservedObject private var settings = SettingsManager.shared
    @Binding var draft: AIProviderSettingsDraft

    private var providerItems: [SegmentItem<AIProviderType>] {
        AIProviderType.allCases.map { SegmentItem(id: $0, title: $0.displayName) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            SettingsSection("Active provider", trailing: {
                KeyHint(label: "Cycle", shortcut: ShortcutCatalog.cycleProvider)
            }) {
                SettingsRow(
                    title: "Provider",
                    helper: "Answers Solve, Design, and Quick Assist requests.",
                    layout: .adaptive
                ) {
                    SegmentStrip(items: providerItems, selection: $settings.selectedProvider)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            Text("Credentials are stored separately for each provider. A stored key is not a connection test.")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
            switch settings.selectedProvider {
            case .claude: ClaudeProviderSection(draft: $draft, isActive: true)
            case .openai: OpenAIProviderSection(draft: $draft, isActive: true)
            case .azureOpenAI: AzureProviderSection(draft: $draft, isActive: true)
            }
            CodingPreferencesSection()
        }
    }
}

/// Badge shown beside the section heading of the provider in use.
struct ProviderActiveBadge: View {
    let isActive: Bool

    var body: some View {
        if isActive {
            ToneBadge(text: "Active", tone: .success, systemImage: "checkmark")
        }
    }
}

/// The language Solve writes code in when the screenshot does not say.
struct CodingPreferencesSection: View {
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        SettingsSection(
            "Coding preferences",
            footer: "Solutions use this language. When a screenshot shows code in another language, that language is matched instead."
        ) {
            SettingsPickerRow(
                title: "Default language",
                options: ProgrammingLanguage.allCases.map { SettingsPickerOption(value: $0, title: $0.rawValue) },
                selection: $settings.preferredLanguage
            )
        }
    }
}
