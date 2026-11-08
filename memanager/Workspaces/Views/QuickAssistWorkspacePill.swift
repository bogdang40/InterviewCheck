import SwiftUI

/// Icon toggle for the active Job Workspace in the thread header: pick or
/// clear the workspace and flip context injection without leaving the
/// overlay. The status bar prints the workspace name.
struct QuickAssistWorkspacePill: View {
    @ObservedObject private var store = WorkspaceStore.shared
    @ObservedObject private var settings = SettingsManager.shared

    private var candidates: [JobWorkspace] {
        store.sortedWorkspaces.filter { !$0.isArchived }
    }

    private var isActive: Bool {
        store.activeWorkspace != nil && settings.workspaceContextEnabled
    }

    var body: some View {
        Menu {
            if candidates.isEmpty {
                Text("No workspaces yet. Create one on the Workspaces screen.")
            } else {
                ForEach(candidates) { workspace in
                    Button {
                        store.setActive(workspace.id)
                    } label: {
                        if store.activeWorkspaceID == workspace.id {
                            Label(workspace.displayTitle, systemImage: "checkmark")
                        } else {
                            Text(workspace.displayTitle)
                        }
                    }
                }
                Divider()
                Button("No workspace") { store.setActive(nil) }
                    .disabled(store.activeWorkspaceID == nil)
            }
            Divider()
            Toggle("Inject workspace context", isOn: $settings.workspaceContextEnabled)
            Toggle("Auto journal turns", isOn: $settings.workspaceJournalAutoRecordEnabled)
        } label: {
            OverlayIconMenuLabel(systemImage: "folder.badge.person.crop", isActive: isActive)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
    }

    private var helpText: String {
        guard let workspace = store.activeWorkspace else {
            return "Pick a Job Workspace to give Quick Assist the job description, your notes, and what you already solved."
        }
        let state = settings.workspaceContextEnabled ? "" : " (context off)"
        return "Active workspace: \(workspace.displayTitle)\(state)\n\(workspace.folderPath)"
    }

    private var accessibilityLabel: String {
        guard let workspace = store.activeWorkspace else { return "Workspace" }
        return settings.workspaceContextEnabled ? "Workspace \(workspace.displayTitle)" : "Workspace \(workspace.displayTitle) off"
    }
}
