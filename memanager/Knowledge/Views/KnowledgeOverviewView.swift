import SwiftUI

/// What the detail pane shows when no fact is selected: what the graph is
/// for, whether Quick Assist is using it, how big it is, and the ways to
/// grow or clear it.
struct KnowledgeOverviewView: View {
    @Binding var contextEnabled: Bool
    @Binding var autoExtractEnabled: Bool
    let counts: KnowledgeGraphCounts
    let message: String?
    let width: CGFloat
    let onAdd: () -> Void
    let onExtract: () -> Void
    let onClear: () -> Void
    let onDismissMessage: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                heading
                if let message {
                    ToneBanner(tone: KnowledgeMessageTone.tone(for: message), message: message, onDismiss: onDismissMessage)
                }
                quickAssistCard
                metrics
                actions
            }
            .frame(maxWidth: OverlayLayout.readingWidth(for: width))
            .frame(maxWidth: .infinity)
            .padding(DesignTokens.Spacing.lg)
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                Text("Knowledge for future answers")
                    .font(OverlayType.display)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                ToneBadge(
                    text: contextEnabled ? "On" : "Off",
                    tone: contextEnabled ? .success : .neutral,
                    systemImage: contextEnabled ? "checkmark" : "pause"
                )
            }
            Text("Keep people, projects, skills and stories available for relevant questions. Review their origins and relationships before relying on an extracted fact.")
                .font(OverlayType.body)
                .foregroundStyle(OverlayPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var quickAssistCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldLabel(text: "Quick Assist")
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.top, DesignTokens.Spacing.md)
                .padding(.bottom, DesignTokens.Spacing.xs)
            SettingsToggleRow(
                title: "Use the knowledge graph in prompts",
                helper: "Relevant facts can join the context for future requests. Selection does not prove the answer used every fact.",
                isOn: $contextEnabled
            )
            Hairline()
            SettingsToggleRow(
                title: "Learn from finished turns",
                helper: "One extra model call per turn extracts new facts and relations.",
                isOn: $autoExtractEnabled
            )
        }
        .overlayCard(.base)
    }

    private var metrics: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            MetricTile(value: "\(counts.nodes)", label: "Facts", systemImage: "circle.hexagongrid")
            MetricTile(value: "\(counts.edges)", label: "Relations", systemImage: "link")
        }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                addButton
                extractButton
                Spacer(minLength: DesignTokens.Spacing.sm)
                clearButton
            }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    addButton
                    extractButton
                }
                clearButton
            }
        }
    }

    private var addButton: some View {
        Button("Add fact", action: onAdd)
            .buttonStyle(.overlayPrimary)
    }

    private var extractButton: some View {
        Button("Extract from text", action: onExtract)
            .buttonStyle(.overlaySecondary)
    }

    private var clearButton: some View {
        Button("Clear graph", action: onClear)
            .buttonStyle(.overlayDestructive)
            .disabled(counts.nodes == 0)
    }
}
