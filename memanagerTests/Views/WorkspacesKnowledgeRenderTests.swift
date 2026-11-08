import AppKit
import SwiftUI
import XCTest
@testable import memanager

/// Renders the Workspaces and Knowledge screens at the three breakpoints,
/// their detail columns with fixture models, and their sheets, to PNG files
/// for visual inspection. Opt in through MEMANAGER_RENDER_SMOKE=1; files
/// land in MEMANAGER_RENDER_DIR or the temp dir.
@MainActor
final class WorkspacesKnowledgeRenderTests: XCTestCase {
    private static let widths: [(name: String, width: CGFloat)] = [
        ("wide", 1000),
        ("regular", 720),
        ("compact", 440)
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        try OverlayRenderHarness.skipUnlessEnabled()
    }

    private func renderAtEachWidth<Content: View>(
        _ name: String,
        height: CGFloat = 900,
        @ViewBuilder content: @escaping (CGFloat) -> Content
    ) async throws {
        for entry in Self.widths {
            try await OverlayRenderHarness.render("\(name)-\(entry.name)", size: CGSize(width: entry.width, height: height)) {
                content(entry.width)
            }
        }
    }

    // MARK: Screens on the live stores

    func testRenderWorkspacesScreen() async throws {
        try await renderAtEachWidth("workspaces-screen") { _ in WorkspacesScreen() }
    }

    func testRenderKnowledgeScreen() async throws {
        try await renderAtEachWidth("knowledge-screen") { _ in KnowledgeScreen() }
    }

    // MARK: Detail columns on fixtures

    func testRenderWorkspaceDetail() async throws {
        let workspace = WorkspacesKnowledgeRenderFixtures.workspace
        try await renderAtEachWidth("workspaces-detail") { width in
            WorkspaceDetailColumn(
                store: WorkspaceStore.shared,
                workspace: workspace,
                breakpoint: OverlayLayout.breakpoint(for: width)
            )
        }
        try await renderAtEachWidth("workspaces-sections", height: 760) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    WorkspaceActionsRow(
                        workspace: workspace,
                        isActive: true,
                        onUse: {}, onReveal: {}, onBind: {}, onArchive: {}, onDelete: {}
                    )
                    WorkspaceDocumentsSection(
                        documents: WorkspacesKnowledgeRenderFixtures.documents,
                        report: WorkspacesKnowledgeRenderFixtures.indexReport,
                        isIndexing: true,
                        onReindex: {},
                        onReveal: {}
                    )
                    WorkspaceJournalSection(
                        entries: WorkspacesKnowledgeRenderFixtures.journal,
                        onAdd: {},
                        onDelete: { _ in }
                    )
                }
                .padding(DesignTokens.Spacing.lg)
            }
        }
    }

    func testRenderKnowledgeDetail() async throws {
        let model = WorkspacesKnowledgeRenderFixtures.knowledgeDetail
        try await renderAtEachWidth("knowledge-detail") { width in
            KnowledgeNodeDetailView(model: model, breakpoint: OverlayLayout.breakpoint(for: width))
        }
        try await renderAtEachWidth("knowledge-relations") { width in
            KnowledgeNodeDetailView(model: model, breakpoint: OverlayLayout.breakpoint(for: width), initialTab: .relations)
        }
    }

    // MARK: List rows on fixtures

    func testRenderListRows() async throws {
        let active = WorkspacesKnowledgeRenderFixtures.workspace
        var applied = JobWorkspace(name: "", company: "Linear", role: "Senior Engineer", status: .applied, folderPath: "/tmp/linear")
        applied.updatedAt = active.updatedAt.addingTimeInterval(-60)
        var archived = JobWorkspace(name: "Acme Platform Lead", company: "Acme", role: "Platform Lead", status: .closed, folderPath: "/tmp/acme")
        archived.isArchived = true
        let facts = WorkspacesKnowledgeRenderFixtures.knowledgeDetail.neighborhood.nodes
        try await OverlayRenderHarness.render("list-rows", size: CGSize(width: 260, height: 420)) {
            VStack(spacing: DesignTokens.Spacing.xxs) {
                SelectableRow(isSelected: true, action: {}) { WorkspaceListRow(workspace: active, isActive: true) }
                SelectableRow(isSelected: false, action: {}) { WorkspaceListRow(workspace: applied, isActive: false) }
                SelectableRow(isSelected: false, action: {}) { WorkspaceListRow(workspace: archived, isActive: false) }
                Hairline()
                ForEach(facts) { fact in
                    SelectableRow(isSelected: fact.id == facts.first?.id, action: {}) { KnowledgeNodeRow(node: fact) }
                }
            }
            .padding(DesignTokens.Spacing.sm)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: Sheets

    func testRenderSheets() async throws {
        try await OverlayRenderHarness.render("workspaces-create-sheet", size: CGSize(width: 520, height: 440)) {
            WorkspaceCreateSheet(store: WorkspaceStore.shared) { _ in }
        }
        try await OverlayRenderHarness.render("knowledge-editor-sheet", size: CGSize(width: 540, height: 480)) {
            KnowledgeNodeEditorSheet(node: WorkspacesKnowledgeRenderFixtures.knowledgeDetail.node) { _ in }
        }
        try await OverlayRenderHarness.render("workspaces-journal-editor", size: CGSize(width: 520, height: 540)) {
            WorkspaceJournalEntrySheet { _, _, _ in }
        }
        try await OverlayRenderHarness.render("knowledge-extraction-sheet", size: CGSize(width: 580, height: 660)) {
            KnowledgeExtractSheet(store: KnowledgeGraphStore.shared)
        }
    }
}
