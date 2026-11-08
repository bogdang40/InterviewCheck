import SwiftUI

/// Paste a resume, a project write up, or interview notes and let the model
/// turn it into graph entries.
struct KnowledgeExtractSheet: View {
    @ObservedObject var store: KnowledgeGraphStore
    @ObservedObject private var workspaceStore = WorkspaceStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var workspaceID: UUID?
    @State private var didInitialize = false
    @State private var extractionFailed = false

    private static let minimumCharacters = 40

    private var workspaces: [JobWorkspace] {
        workspaceStore.sortedWorkspaces.filter { !$0.isArchived }
    }

    private var selectedWorkspace: JobWorkspace? {
        workspaceID.flatMap { workspaceStore.workspace(id: $0) }
    }

    private var canExtract: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.minimumCharacters && !store.isExtracting
    }

    var body: some View {
        OverlaySheetFrame(
            title: "Extract facts from text",
            subtitle: "Paste a resume section, a project write up, or interview notes. One model call extracts people, companies, projects, skills, stories, and problems, then merges them into your graph.",
            width: 520,
            primaryTitle: "Extract",
            isPrimaryEnabled: canExtract,
            busyCaption: store.isExtracting ? "Extracting" : nil,
            cancelTitle: "Close",
            onPrimary: extract,
            onCancel: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                OverlayTextEditor(placeholder: "Paste at least a few sentences", text: $text, height: 220)
                LabeledField("Attach to workspace", hint: "Facts inherit the workspace so retrieval can favour them while it is active.") {
                    workspaceMenu
                }
                Text("At least \(Self.minimumCharacters) characters. Extracted facts should be reviewed against your source text.")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
                if extractionFailed, let message = store.lastMessage {
                    ToneBanner(tone: .critical, title: "Extraction did not finish", message: message)
                }
            }
        }
        .onAppear {
            guard !didInitialize else { return }
            didInitialize = true
            workspaceID = workspaceStore.activeWorkspaceID
        }
        .interactiveDismissDisabled(store.isExtracting)
    }

    private var workspaceMenu: some View {
        MenuField(
            title: selectedWorkspace?.displayTitle ?? "None",
            systemImage: "folder.badge.person.crop",
            isPlaceholder: selectedWorkspace == nil
        ) {
            Button("None") { workspaceID = nil }
            if !workspaces.isEmpty {
                Divider()
            }
            ForEach(workspaces) { workspace in
                Button(workspace.displayTitle) { workspaceID = workspace.id }
            }
        }
    }

    private func extract() {
        guard canExtract else { return }
        let workspace = selectedWorkspace
        Task {
            let succeeded = await store.extract(from: text, workspace: workspace)
            extractionFailed = !succeeded
            if succeeded { dismiss() }
        }
    }
}
