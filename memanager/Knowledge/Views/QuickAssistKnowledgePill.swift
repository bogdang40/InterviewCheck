import SwiftUI

/// Icon toggle for graph retrieval in the thread header. The menu carries
/// the switches and how many facts the graph holds.
struct QuickAssistKnowledgePill: View {
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var store = KnowledgeGraphStore.shared

    var body: some View {
        Menu {
            Toggle("Use knowledge graph", isOn: $settings.knowledgeContextEnabled)
            Toggle("Learn from turns (extra model call)", isOn: $settings.knowledgeAutoExtractEnabled)
            Divider()
            Text("\(store.counts.nodes) facts, \(store.counts.edges) relations")
        } label: {
            OverlayIconMenuLabel(
                systemImage: "point.3.connected.trianglepath.dotted",
                isActive: settings.knowledgeContextEnabled
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onAppear { store.refresh() }
        .help(settings.knowledgeContextEnabled
              ? "Knowledge graph on: facts about you (people, companies, projects, stories) ride along with each answer"
              : "Knowledge graph off")
        .accessibilityLabel(settings.knowledgeContextEnabled ? "Knowledge graph on" : "Knowledge graph off")
    }
}
