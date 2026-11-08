import SwiftUI

/// Indexed files grouped by shelf, each shelf a disclosure card, with the
/// last index report and the two controls that change what is indexed.
struct WorkspaceDocumentsSection: View {
    let documents: [WorkspaceDocument]
    let report: WorkspaceIndexReport?
    let isIndexing: Bool
    let onReindex: () -> Void
    let onReveal: () -> Void

    @State private var collapsedShelves: Set<WorkspaceDocumentCategory> = []
    @State private var selectedCategory: WorkspaceDocumentCategory?
    @State private var showsFailures = false

    private var shelves: [WorkspaceDocumentShelf] {
        WorkspaceDocumentShelves.group(documents.filter { selectedCategory == nil || $0.category == selectedCategory })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            header
            reportLine
            ScrollView(.horizontal, showsIndicators: false) {
                SegmentStrip(items: [SegmentItem<WorkspaceDocumentCategory?>(id: nil, title: "All")]
                    + WorkspaceDocumentCategory.allCases.map { SegmentItem<WorkspaceDocumentCategory?>(id: $0, title: $0.displayName) }, selection: $selectedCategory)
            }
            if shelves.isEmpty {
                emptyState
            } else {
                ForEach(shelves) { shelf in
                    DisclosureCard(
                        shelf.category.displayName,
                        systemImage: shelf.category.systemImage,
                        count: shelf.documents.count,
                        isExpanded: expansion(for: shelf.category)
                    ) {
                        VStack(spacing: DesignTokens.Spacing.xxs) {
                            ForEach(shelf.documents) { document in
                                WorkspaceDocumentRow(document: document)
                            }
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        SurfaceHeader("Documents", systemImage: "doc.on.doc", count: documents.count, prominence: .heading) {
            if isIndexing {
                ProgressCaption(text: "Indexing")
            }
            Button("Reindex", action: onReindex)
                .buttonStyle(.overlay(.secondary, size: .small))
                .disabled(isIndexing)
            Button("Add files", action: onReveal)
                .buttonStyle(.overlay(.secondary, size: .small))
                .help("Opens the folder in Finder. Drop files in, then re index.")
        }
    }

    @ViewBuilder
    private var reportLine: some View {
        if let report {
            if report.failures.isEmpty {
                Text("Last index: \(report.summary)")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
            } else {
                ToneBanner(tone: .warning, message: "Last index: \(report.summary)")
                DisclosureCard("Indexing issues", systemImage: "exclamationmark.triangle", count: report.failures.count, isExpanded: $showsFailures) {
                    ForEach(Array(report.failures.enumerated()), id: \.offset) { _, failure in
                        Text(failure)
                            .font(OverlayType.caption)
                            .foregroundStyle(OverlayPalette.textSecondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        OverlayCompactEmptyState(
            systemImage: "doc.badge.plus",
            title: selectedCategory.map { "No \($0.displayName.lowercased()) files indexed" } ?? "Nothing indexed yet",
            message: "Add files in the workspace folder, then reindex. Images and unsupported formats stay listed without searchable text.",
            action: EmptyStateAction(title: "Add files", action: onReveal)
        )
        .overlayCard(.base)
    }

    private func expansion(for category: WorkspaceDocumentCategory) -> Binding<Bool> {
        Binding(
            get: { !collapsedShelves.contains(category) },
            set: { expanded in
                if expanded {
                    collapsedShelves.remove(category)
                } else {
                    collapsedShelves.insert(category)
                }
            }
        )
    }
}
