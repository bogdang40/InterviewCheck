import SwiftUI

enum KnowledgeDetailTab: String, CaseIterable, Identifiable {
    case evidence, relations
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Fact content and recorded origin are separate from its graph relations.
struct KnowledgeNodeDetailView: View {
    let model: KnowledgeNodeDetailModel
    var actions: KnowledgeNodeDetailActions = .inert
    var breakpoint: OverlayLayout.Breakpoint = .regular
    @State private var tab: KnowledgeDetailTab = .evidence

    init(model: KnowledgeNodeDetailModel, actions: KnowledgeNodeDetailActions = .inert, breakpoint: OverlayLayout.Breakpoint = .regular, initialTab: KnowledgeDetailTab = .evidence) {
        self.model = model
        self.actions = actions
        self.breakpoint = breakpoint
        _tab = State(initialValue: initialTab)
    }

    private var node: KnowledgeNode { model.node }
    private var summary: String? {
        let value = node.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    var body: some View {
        VStack(spacing: 0) {
            SurfaceHeader(node.label, systemImage: node.kind.systemImage) {
                ToneBadge(text: node.kind.displayName, tone: .info)
            }
            .padding(DesignTokens.Spacing.md)
            SegmentStrip(items: KnowledgeDetailTab.allCases.map { SegmentItem(id: $0, title: $0.title) }, selection: $tab)
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.bottom, DesignTokens.Spacing.sm)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    if let message = model.message {
                        ToneBanner(tone: KnowledgeMessageTone.tone(for: message), message: message, onDismiss: actions.dismissMessage)
                    }
                    evidence
                        .frame(height: tab == .evidence ? nil : 0, alignment: .top)
                        .clipped().opacity(tab == .evidence ? 1 : 0)
                        .allowsHitTesting(tab == .evidence).accessibilityHidden(tab != .evidence)
                        .disabled(tab != .evidence)
                    relations
                        .frame(height: tab == .relations ? nil : 0, alignment: .top)
                        .clipped().opacity(tab == .relations ? 1 : 0)
                        .allowsHitTesting(tab == .relations).accessibilityHidden(tab != .relations)
                        .disabled(tab != .relations)
                }
                .padding(DesignTokens.Spacing.lg)
            }
            Hairline()
            WrappingFlowLayout {
                Button("Edit fact", systemImage: "pencil", action: actions.edit).buttonStyle(.overlaySecondary)
                Button("Link fact", systemImage: "link") { tab = .relations }.buttonStyle(.overlaySecondary)
                Button("Delete fact", role: .destructive, action: actions.delete).buttonStyle(.overlayDestructive)
            }
            .padding(DesignTokens.Spacing.md)
        }
    }

    private var evidence: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            if let summary {
                Text(summary)
                    .font(OverlayType.title)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Label("Recorded origin", systemImage: "doc.text")
                    .font(OverlayType.callout)
                    .foregroundStyle(OverlayPalette.textPrimary)
                Text(KnowledgeNodePresentation.sourceLine(for: node))
                    .font(OverlayType.body)
                    .foregroundStyle(OverlayPalette.textSecondary)
                if let reference = node.sourceRef, !reference.isEmpty {
                    Text(reference)
                        .font(OverlayType.mono)
                        .foregroundStyle(OverlayPalette.textPrimary)
                        .textSelection(.enabled)
                } else {
                    Text("No source reference was stored.")
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textSecondary)
                }
                Text("A stored origin identifies where a fact came from. It does not verify the claim or preserve the original source text.")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Spacing.md)
            .overlayCard(.base)
            KeyValueGrid(pairs: [
                KeyValuePair(key: "Mentions", value: "\(node.mentionCount)"),
                KeyValuePair(key: "Updated", value: node.updatedAt.formatted(date: .abbreviated, time: .shortened))
            ])
            if !node.properties.isEmpty {
                KeyValueGrid(pairs: KeyValuePair.sorted(node.properties))
            }
        }
    }

    private var relations: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            KnowledgeRelationsList(node: node, graph: model.neighborhood, onNavigate: actions.select, onDelete: actions.deleteEdge)
            if !model.neighborhood.edges.isEmpty {
                KnowledgeGraphCanvasView(graph: model.neighborhood, centerID: node.id, onSelect: actions.select)
                    .frame(height: breakpoint == .compact ? 200 : 260)
                    .overlayCard(.base)
            }
            KnowledgeLinkForm(targets: model.linkTargets, onLink: actions.link)
        }
    }
}
